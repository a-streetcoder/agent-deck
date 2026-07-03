import { randomUUID } from "node:crypto";
import {
  createIngestState,
  emptyTranscript,
  ingestPiEvent,
  reduceTranscript,
  type IngestState,
  type SessionMeta,
  type TranscriptState,
} from "@agent-deck/domain";
import {
  buildLaunchArgs,
  PiSession,
  resolvePiBinary,
  type AgentSessionPlan,
  type LaunchPlan,
  type ModelSelection,
  type PiProcessExit,
} from "@agent-deck/pi-host";
export type { AgentSessionPlan, LaunchPlan };
import { SessionPushBus } from "./pushBus.ts";
import type { ReceiptBus } from "./receipts.ts";

export interface CreateSessionOptions {
  cwd: string;
  plan: LaunchPlan;
  projectId?: string;
  agentName?: string;
  /** Extra env for the pi subprocess (merged over process.env). */
  env?: Record<string, string | undefined>;
}

const TITLE_SYSTEM_PROMPT =
  "You generate a session title. Reply with ONLY a short title (max 8 words) " +
  "summarizing the user's message. No quotes, no punctuation at the end.";

const TITLE_TIMEOUT_MS = 20_000;

function normalizeTitle(raw: string): string {
  const firstLine =
    raw
      .split("\n", 1)[0]
      ?.trim()
      .replace(/^["'"']|["'"']$/g, "") ?? "";
  return firstLine.length > 60 ? `${firstLine.slice(0, 57)}…` : firstLine;
}

/**
 * One live chat session: a PiSession whose events flow through the ingest
 * pipeline into (a) the authoritative in-memory transcript and (b) the ordered
 * push bus that clients subscribe to. Ingestion is synchronous, so stamping
 * happens in pi-stdout order — no async fan-out before seq assignment.
 */
export class ManagedSession {
  readonly bus = new SessionPushBus();
  private readonly ingest: IngestState = createIngestState();
  private transcript: TranscriptState = emptyTranscript();
  private sawFirstDelta = false;
  private titleStarted = false;
  /** Open extension_ui_requests: id → method. Answers must match one. */
  private readonly pendingUiRequests = new Map<string, string>();
  /** While seeding history on resume, live pi events are queued, not applied. */
  private seedGate: Array<Parameters<typeof ingestPiEvent>[1]> | null = null;
  exit: PiProcessExit | null = null;

  constructor(
    readonly meta: SessionMeta,
    private readonly pi: PiSession,
    private readonly receipts: ReceiptBus,
    private readonly onMetaChange: (meta: SessionMeta) => void = () => {},
    /** Provider/model/extensions + env for the isolated title-helper launch. */
    private readonly helperContext?: ModelSelection & {
      extensions?: string[];
      env?: Record<string, string | undefined>;
    },
  ) {
    pi.on("event", (piEvent) => {
      if (this.seedGate) {
        this.seedGate.push(piEvent);
        return;
      }
      this.applyPiEvent(piEvent);
    });
    pi.on("exit", (exit) => {
      this.exit = exit;
      this.meta.endedAt = new Date().toISOString();
      this.onMetaChange(this.meta);
    });
  }

  private applyPiEvent(piEvent: Parameters<typeof ingestPiEvent>[1]): void {
    if (piEvent.type === "extension_ui_request") {
      this.pendingUiRequests.set(piEvent.id, piEvent.method);
    }
    for (const domainEvent of ingestPiEvent(this.ingest, piEvent)) {
      this.transcript = reduceTranscript(this.transcript, domainEvent);
      this.bus.append(domainEvent);
      if (domainEvent.type === "cell_delta" && !this.sawFirstDelta) {
        this.sawFirstDelta = true;
        this.receipts.emit("first_delta", this.meta.id);
      }
      if (domainEvent.type === "cell_final" && domainEvent.cell.kind === "assistant") {
        this.receipts.emit("assistant_final", this.meta.id);
      }
      if (domainEvent.type === "agent_status" && domainEvent.status === "idle") {
        this.receipts.emit("idle", this.meta.id);
        this.captureSessionFile();
        void this.generateTitle();
      }
    }
  }

  /** Record pi's canonical session file (the resume handle) once it exists. */
  private captureSessionFile(): void {
    if (this.meta.piSessionFile || !this.pi.isRunning) return;
    void this.pi
      .getState()
      .then((state) => {
        if (state.sessionFile && !this.meta.piSessionFile) {
          this.meta.piSessionFile = state.sessionFile;
          this.onMetaChange(this.meta);
        }
      })
      .catch(() => {
        // Exited or unresponsive — nothing to record.
      });
  }

  /**
   * Isolated title-helper launch (pi-rpc-launch-flags.md §3): no session, no
   * tools, no resources; sends only the first user message.
   */
  private async generateTitle(): Promise<void> {
    if (this.titleStarted || this.meta.title) return;
    const firstUser = this.transcript.cells.find((cell) => cell.kind === "user");
    if (!firstUser || firstUser.kind !== "user" || !firstUser.text.trim()) return;
    this.titleStarted = true;

    const helper = new PiSession({
      binPath: resolvePiBinary().path,
      args: buildLaunchArgs({
        kind: "helper",
        systemPrompt: TITLE_SYSTEM_PROMPT,
        provider: this.helperContext?.provider,
        model: this.helperContext?.model,
        extensions: this.helperContext?.extensions,
      }),
      cwd: this.meta.cwd,
      env: this.helperContext?.env,
      requestTimeoutMs: TITLE_TIMEOUT_MS,
    });
    try {
      const idle = new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error("title helper timeout")), TITLE_TIMEOUT_MS);
        timer.unref();
        helper.on("event", (event) => {
          if ((event as { type: string }).type === "agent_end") {
            clearTimeout(timer);
            resolve();
          }
        });
        helper.on("exit", () => reject(new Error("title helper exited")));
      });
      // Mark handled up front: a startup exit must never become an unhandled
      // rejection while we're still awaiting prompt().
      idle.catch(() => {});
      helper.start();
      await helper.prompt(firstUser.text.slice(0, 2000));
      await idle;
      const { text } = await helper.request({ type: "get_last_assistant_text" });
      const title = text ? normalizeTitle(text) : "";
      if (title) {
        this.meta.title = title;
        this.onMetaChange(this.meta);
        this.receipts.emit("title", this.meta.id);
      }
    } catch {
      this.titleStarted = false; // retry on a later idle
    } finally {
      await helper.stop();
    }
  }

  /** Queue live pi events until seedFromHistory finishes (resume path). */
  holdLiveEvents(): void {
    this.seedGate = [];
  }

  /**
   * Rebuild the transcript from pi's canonical history (resume path). Live
   * events received meanwhile were queued and are applied strictly after the
   * seed, preserving order.
   */
  async seedFromHistory(): Promise<void> {
    try {
      const { messages } = await this.pi.getMessages();
      for (const message of messages) {
        for (const domainEvent of ingestPiEvent(this.ingest, {
          type: "message_end",
          message,
        } as Parameters<typeof ingestPiEvent>[1])) {
          this.transcript = reduceTranscript(this.transcript, domainEvent);
          this.bus.append(domainEvent);
        }
      }
    } finally {
      const queued = this.seedGate ?? [];
      this.seedGate = null;
      for (const piEvent of queued) this.applyPiEvent(piEvent);
    }
  }

  snapshot(): { seq: number; state: TranscriptState } {
    return { seq: this.bus.lastSeq, state: this.transcript };
  }

  get isRunning(): boolean {
    return this.pi.isRunning;
  }

  async prompt(message: string): Promise<void> {
    await this.pi.prompt(message);
  }

  async steer(message: string): Promise<void> {
    await this.pi.steer(message);
  }

  async followUp(message: string): Promise<void> {
    await this.pi.followUp(message);
  }

  async abort(): Promise<void> {
    await this.pi.abort();
  }

  /**
   * Answer an extension UI request. The client's payload is NOT forwarded
   * raw: the id must match an open request and the response is rebuilt here
   * in the exact typed shape pi expects (RpcExtensionUIResponse).
   */
  respondToUiRequest(raw: Record<string, unknown>): void {
    const id = raw.id;
    if (typeof id !== "string" || !this.pendingUiRequests.has(id)) {
      throw new Error("no open extension UI request with that id");
    }
    let response: { type: "extension_ui_response"; id: string } & Record<string, unknown>;
    if (raw.cancelled === true) {
      response = { type: "extension_ui_response", id, cancelled: true };
    } else if (typeof raw.confirmed === "boolean") {
      response = { type: "extension_ui_response", id, confirmed: raw.confirmed };
    } else if (typeof raw.value === "string") {
      response = { type: "extension_ui_response", id, value: raw.value };
    } else {
      throw new Error("ui response must carry cancelled, confirmed, or a string value");
    }
    this.pendingUiRequests.delete(id);
    this.pi.respondToUiRequest(response as Parameters<PiSession["respondToUiRequest"]>[0]);
    // The card is answered from the transcript's point of view immediately.
    const domainEvent = { type: "question_answered", cellId: `question-${id}` } as const;
    this.transcript = reduceTranscript(this.transcript, domainEvent);
    this.bus.append(domainEvent);
  }

  async getCommands(): Promise<Awaited<ReturnType<PiSession["getCommands"]>>> {
    return await this.pi.getCommands();
  }

  async getState(): Promise<Awaited<ReturnType<PiSession["getState"]>>> {
    return await this.pi.getState();
  }

  async getAvailableModels(): Promise<Awaited<ReturnType<PiSession["getAvailableModels"]>>> {
    return await this.pi.getAvailableModels();
  }

  async setModel(provider: string, modelId: string): Promise<void> {
    await this.pi.setModel(provider, modelId);
  }

  async setThinkingLevel(level: Parameters<PiSession["setThinkingLevel"]>[0]): Promise<void> {
    await this.pi.setThinkingLevel(level);
  }

  /** Subscribe to process exit; returns an unsubscribe. Fires immediately if already exited. */
  onExit(listener: (exit: PiProcessExit) => void): () => void {
    if (this.exit) {
      listener(this.exit);
      return () => {};
    }
    this.pi.on("exit", listener);
    return () => this.pi.off("exit", listener);
  }

  async stop(): Promise<void> {
    await this.pi.stop();
  }
}

export class SessionManager {
  private readonly sessions = new Map<string, ManagedSession>();
  /** In-flight resumes by session id — double-resume returns the same promise. */
  private readonly resuming = new Map<string, Promise<ManagedSession>>();

  constructor(
    private readonly receipts: ReceiptBus,
    private readonly onMetaChange: (meta: SessionMeta) => void = () => {},
    /** Provider-registration extensions — the ONLY ones helper launches load. */
    private readonly helperExtensions: () => string[] | undefined = () => undefined,
  ) {}

  create(options: CreateSessionOptions): ManagedSession {
    const meta: SessionMeta = {
      id: randomUUID(),
      cwd: options.cwd,
      createdAt: new Date().toISOString(),
      projectId: options.projectId,
      agentName: options.agentName,
      launchPlan: options.plan,
    };
    return this.launch(meta, options.plan, options.env);
  }

  /**
   * Relaunch a persisted session against its pi session file, with the SAME
   * launch shape it was created with, rebuilding the transcript from pi's
   * canonical history before any live events. Concurrent resumes of the same
   * id share one relaunch.
   */
  async resume(
    meta: SessionMeta,
    fallbackPlan: LaunchPlan,
    env?: Record<string, string | undefined>,
  ): Promise<ManagedSession> {
    const inFlight = this.resuming.get(meta.id);
    if (inFlight) return await inFlight;

    const original = (meta.launchPlan as LaunchPlan | undefined) ?? fallbackPlan;
    let plan: LaunchPlan;
    if (original.kind === "agent") {
      plan = { ...original, sessionDir: undefined, resumeSessionPath: meta.piSessionFile };
    } else if (original.kind === "parent") {
      plan = { ...original, resumeSessionPath: meta.piSessionFile };
    } else {
      plan = original;
    }

    const task = (async () => {
      const revived: SessionMeta = { ...meta, endedAt: undefined };
      const session = this.launch(revived, plan, env, { holdLive: true });
      await session.seedFromHistory();
      this.onMetaChange(revived);
      return session;
    })();
    this.resuming.set(meta.id, task);
    try {
      return await task;
    } finally {
      this.resuming.delete(meta.id);
    }
  }

  private launch(
    meta: SessionMeta,
    plan: LaunchPlan,
    env?: Record<string, string | undefined>,
    options?: { holdLive?: boolean },
  ): ManagedSession {
    const pi = new PiSession({
      binPath: resolvePiBinary().path,
      args: buildLaunchArgs(plan),
      cwd: meta.cwd,
      env,
    });
    const helperContext = {
      provider: plan.provider,
      model: plan.model,
      // Helpers stay resource-free (launch contract §3) except for
      // provider-registration extensions, which custom providers require.
      extensions: this.helperExtensions(),
      env,
    };
    const session = new ManagedSession(meta, pi, this.receipts, this.onMetaChange, helperContext);
    if (options?.holdLive) session.holdLiveEvents();
    this.sessions.set(meta.id, session);
    pi.start();
    this.receipts.emit("session_created", meta.id);
    this.onMetaChange(meta);
    return session;
  }

  get(id: string): ManagedSession | undefined {
    return this.sessions.get(id);
  }

  list(): SessionMeta[] {
    return [...this.sessions.values()].map((session) => session.meta);
  }

  async stopAll(): Promise<void> {
    await Promise.all([...this.sessions.values()].map((session) => session.stop()));
  }
}
