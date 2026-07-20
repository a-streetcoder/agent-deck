import { EventEmitter } from "node:events";
import type {
  RpcCommand,
  RpcResponse,
  RpcEventListener,
  RpcExtensionUIRequest,
  RpcExtensionUIResponse,
  RpcSessionState,
} from "@earendil-works/pi-coding-agent";
import { serializeJsonLine } from "./jsonl.ts";
import { PiProcess, type PiProcessExit } from "./PiProcess.ts";

/** pi's streaming event union, derived from the exported listener type. */
export type PiAgentEvent = Parameters<RpcEventListener>[0];

/** Everything pi pushes that is not a command response. */
export type PiInboundEvent = PiAgentEvent | RpcExtensionUIRequest;

type CommandType = RpcCommand["type"];
type CommandOf<T extends CommandType> = Extract<RpcCommand, { type: T }>;
type ResponseOf<T extends CommandType> = Extract<RpcResponse, { command: T }>;
type DataOf<T extends CommandType> = ResponseOf<T> extends { data: infer D } ? D : undefined;

/** Not re-exported from pi's package root — derived from the response shape. */
export type RpcSlashCommand = DataOf<"get_commands">["commands"][number];

/**
 * Typed RPC command surface, exported for wrappers that implement their own
 * correlation on top of PiProcess (the server's Effect service does): the
 * command-type union, the full command shape per type, its response `data`,
 * plus the raw response and extension-UI response unions.
 */
export type PiCommandType = CommandType;
export type PiCommand<T extends PiCommandType> = CommandOf<T>;
export type PiCommandData<T extends PiCommandType> = DataOf<T>;
export type PiRpcResponse = RpcResponse;
export type PiUiResponse = RpcExtensionUIResponse;

export class PiRpcError extends Error {
  constructor(
    message: string,
    readonly command: CommandType,
    readonly stderr?: string,
  ) {
    super(message);
  }
}

interface PendingRequest {
  command: CommandType;
  resolve: (response: unknown) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout | null;
}

export interface PiSessionOptions {
  binPath: string;
  /** Full launch args (from buildLaunchArgs) — must include `--mode rpc`. */
  args: string[];
  cwd: string;
  env?: Record<string, string | undefined>;
  /** Default timeout for request/response commands. `prompt`/`steer`/`follow_up` ack fast. */
  requestTimeoutMs?: number;
}

export interface PiSessionEvents {
  event: [PiInboundEvent];
  /** A stdout line that was not valid JSON — surfaced, never thrown. */
  "malformed-line": [string];
  exit: [PiProcessExit];
}

/**
 * One live pi RPC session: request/response correlation over a PiProcess, with
 * everything else fanned out as ordered `event`s. The method surface mirrors pi's
 * own RpcClient so tests can use pi's client as an oracle.
 */
export class PiSession extends EventEmitter<PiSessionEvents> {
  private readonly process: PiProcess;
  private readonly pending = new Map<string, PendingRequest>();
  private nextRequestId = 0;
  private readonly requestTimeoutMs: number;

  constructor(options: PiSessionOptions) {
    super();
    this.requestTimeoutMs = options.requestTimeoutMs ?? 20_000;
    this.process = new PiProcess({
      binPath: options.binPath,
      args: options.args,
      cwd: options.cwd,
      env: options.env,
    });
    this.process.on("line", (line) => this.handleLine(line));
    this.process.on("exit", (exit) => {
      this.rejectAllPending(
        new PiRpcError(
          `pi exited (code=${exit.code}, signal=${exit.signal}) before responding`,
          "get_state",
          this.process.stderr,
        ),
      );
      this.emit("exit", exit);
    });
  }

  start(): void {
    this.process.start();
  }

  get isRunning(): boolean {
    return this.process.isRunning;
  }

  get stderr(): string {
    return this.process.stderr;
  }

  async stop(): Promise<PiProcessExit> {
    return await this.process.stop();
  }

  /**
   * Send a command and await its correlated response's `data`.
   * Rejects on `success: false`, timeout, or process exit.
   */
  async request<T extends CommandType>(
    command: Omit<CommandOf<T>, "id"> & { type: T },
    timeoutMs: number = this.requestTimeoutMs,
  ): Promise<DataOf<T>> {
    const id = `req-${this.nextRequestId++}`;
    const promise = new Promise<unknown>((resolve, reject) => {
      const timer =
        timeoutMs > 0
          ? setTimeout(() => {
              this.pending.delete(id);
              reject(
                new PiRpcError(
                  `pi did not respond to ${command.type} within ${timeoutMs}ms`,
                  command.type,
                  this.process.stderr,
                ),
              );
            }, timeoutMs)
          : null;
      timer?.unref();
      this.pending.set(id, { command: command.type, resolve, reject, timer });
    });
    this.process.writeLine(serializeJsonLine({ ...command, id }));
    return (await promise) as DataOf<T>;
  }

  /** Answer an extension_ui_request (question cards, confirmations, …). */
  respondToUiRequest(response: RpcExtensionUIResponse): void {
    this.process.writeLine(serializeJsonLine(response));
  }

  // Convenience wrappers mirroring pi's RpcClient names.

  async prompt(message: string, images?: CommandOf<"prompt">["images"]): Promise<void> {
    await this.request({ type: "prompt", message, images });
  }

  async steer(message: string): Promise<void> {
    await this.request({ type: "steer", message });
  }

  async followUp(message: string): Promise<void> {
    await this.request({ type: "follow_up", message });
  }

  async abort(): Promise<void> {
    await this.request({ type: "abort" });
  }

  /**
   * Manually compact the session: pi summarizes older history to free context,
   * emitting a `compaction_end` (reason "manual"). Blocks until the summarization
   * completes (an LLM call), so it uses a generous timeout rather than the fast
   * ack path of prompt/steer.
   */
  async compact(): Promise<void> {
    await this.request({ type: "compact" }, 120_000);
  }

  async getState(): Promise<RpcSessionState> {
    return await this.request({ type: "get_state" });
  }

  /**
   * Token/cost/context-usage totals for the live session (native session
   * context-usage indicator). `contextUsage` is undefined/null until the first
   * LLM response has established a context estimate.
   */
  async getSessionStats(): Promise<DataOf<"get_session_stats">> {
    return await this.request({ type: "get_session_stats" });
  }

  async getCommands(): Promise<RpcSlashCommand[]> {
    const data = await this.request({ type: "get_commands" });
    return data.commands;
  }

  async getEntries(since?: string): Promise<DataOf<"get_entries">> {
    return await this.request({ type: "get_entries", since });
  }

  async getMessages(): Promise<DataOf<"get_messages">> {
    return await this.request({ type: "get_messages" });
  }

  async setModel(provider: string, modelId: string): Promise<DataOf<"set_model">> {
    return await this.request({ type: "set_model", provider, modelId });
  }

  async getAvailableModels(): Promise<DataOf<"get_available_models">["models"]> {
    const data = await this.request({ type: "get_available_models" });
    return data.models;
  }

  async setThinkingLevel(level: CommandOf<"set_thinking_level">["level"]): Promise<void> {
    await this.request({ type: "set_thinking_level", level });
  }

  async setSessionName(name: string): Promise<void> {
    await this.request({ type: "set_session_name", name });
  }

  private handleLine(line: string): void {
    if (line.trim().length === 0) return;
    let parsed: unknown;
    try {
      parsed = JSON.parse(line);
    } catch {
      this.emit("malformed-line", line);
      return;
    }
    if (typeof parsed !== "object" || parsed === null || !("type" in parsed)) {
      this.emit("malformed-line", line);
      return;
    }
    const record = parsed as { type: string; id?: string };
    if (record.type === "response") {
      this.handleResponse(record as RpcResponse);
      return;
    }
    this.emit("event", parsed as PiInboundEvent);
  }

  private handleResponse(response: RpcResponse): void {
    if (!response.id) return;
    const pending = this.pending.get(response.id);
    if (!pending) return;
    this.pending.delete(response.id);
    if (pending.timer) clearTimeout(pending.timer);
    if (!response.success) {
      pending.reject(new PiRpcError(response.error, pending.command, this.process.stderr));
      return;
    }
    pending.resolve("data" in response ? response.data : undefined);
  }

  private rejectAllPending(error: Error): void {
    for (const pending of this.pending.values()) {
      if (pending.timer) clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }
}
