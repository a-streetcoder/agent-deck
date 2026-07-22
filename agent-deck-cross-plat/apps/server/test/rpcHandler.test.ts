import { describe, expect, it, vi } from "vitest";
import { Schema } from "effect";
import { RpcServerFrame } from "@agent-deck/contracts";
import type { DiscoveredServer, RpcServerFrame as Frame } from "@agent-deck/contracts";
import type { DiffGateway } from "../src/diffGateway.ts";
import type { EditorLauncher, EditorOpenInput } from "../src/editorLauncher.ts";
import { createRpcConnection } from "../src/rpcHandler.ts";
import type { OpenedScript, ScriptRunnerGateway } from "../src/scriptRunnerGateway.ts";
import type { ManagedSession, SessionManager } from "../src/SessionManager.ts";
import type { FileService } from "../src/services/files.ts";
import type { StampedEvent } from "../src/services/pushBus.ts";
import type { ScriptEvent } from "../src/services/scriptRunner.ts";
import type { TerminalEvent } from "../src/services/terminal.ts";
import type { OpenedTerminal, TerminalGateway } from "../src/terminalGateway.ts";

/**
 * Unit tests for the Effect-RPC connection core (rpcHandler.ts) — the same
 * operation surface + seq/replay/snapshot semantics as the legacy `/ws`
 * envelope, exercised against a fake SessionManager with a plain `send`
 * collector (no `ws`, no runtime). Every outbound frame is asserted to be a
 * contract-valid `RpcServerFrame`.
 */

const decodeFrame = Schema.decodeUnknownEither(RpcServerFrame);

interface FakeBus {
  subscribe: (fn: (s: StampedEvent) => void) => () => void;
  emit: (event: StampedEvent) => void;
  replayFrom: (lastSeq: number) => StampedEvent[] | null;
}

function makeSession(
  id: string,
  opts?: {
    replay?: StampedEvent[] | null;
    snapshot?: { seq: number; state: unknown };
    /** Session already ended: meta carries endedAt (manager keeps it listed). */
    endedAt?: string;
    /** Session exit already happened: onExit fires its listener immediately. */
    exitImmediately?: boolean;
  },
) {
  let subscriber: ((s: StampedEvent) => void) | null = null;
  const unsubscribe = vi.fn();
  const bus: FakeBus = {
    subscribe: (fn) => {
      subscriber = fn;
      return unsubscribe;
    },
    emit: (event) => subscriber?.(event),
    replayFrom: () => opts?.replay ?? null,
  };
  const ops = {
    prompt: vi.fn(async () => {}),
    steer: vi.fn(async () => {}),
    abort: vi.fn(async () => {}),
    compact: vi.fn(async () => {}),
    setModel: vi.fn(async () => {}),
    setThinkingLevel: vi.fn(async () => {}),
    respondToUiRequest: vi.fn(),
    getAvailableModels: vi.fn(async () => [{ provider: "anthropic", id: "sonnet" }]),
  };
  const exitListeners = new Set<() => void>();
  const exitUnhook = vi.fn();
  const session = {
    meta: {
      id,
      cwd: "/tmp",
      createdAt: "2026-01-01T00:00:00.000Z",
      ...(opts?.endedAt !== undefined ? { endedAt: opts.endedAt } : {}),
    },
    bus: {
      subscribe: bus.subscribe,
      replayFrom: bus.replayFrom,
      get lastSeq() {
        return 0;
      },
    },
    onExit: (fn: () => void) => {
      // Mirrors services/sessionManager.ts: an already-exited session fires
      // the listener SYNCHRONOUSLY and returns a no-op unhook.
      if (opts?.exitImmediately) {
        fn();
        return exitUnhook;
      }
      exitListeners.add(fn);
      return () => exitListeners.delete(fn);
    },
    snapshot: () => opts?.snapshot ?? { seq: 0, state: { cells: [] } },
    ...ops,
  } as unknown as ManagedSession;
  const triggerExit = (): void => {
    for (const listener of [...exitListeners]) listener();
  };
  return { session, bus, unsubscribe, ops, triggerExit, exitUnhook };
}

// --- Fake terminal gateway (Slice 8a): scripted PTY handles, no runtime ---

interface FakeTerminal {
  readonly opened: OpenedTerminal;
  /** Simulate PTY output/exit reaching the service listeners (+ scrollback). */
  emit: (event: TerminalEvent) => void;
  listenerCount: () => number;
  write: ReturnType<typeof vi.fn>;
  resize: ReturnType<typeof vi.fn>;
  pause: ReturnType<typeof vi.fn>;
  resume: ReturnType<typeof vi.fn>;
  close: ReturnType<typeof vi.fn>;
}

function makeFakeTerminal(terminalId: string, sessionId: string): FakeTerminal {
  const listeners = new Set<(event: TerminalEvent) => void>();
  let scrollback = "";
  let running = true;
  const emit = (event: TerminalEvent): void => {
    if (event._tag === "Output") scrollback += event.data;
    else running = false;
    for (const listener of [...listeners]) listener(event);
  };
  const write = vi.fn(async () => {});
  const resize = vi.fn(async () => {});
  const pause = vi.fn();
  const resume = vi.fn();
  const close = vi.fn(async () => {
    // The scope-close release kills the PTY → the exit event fires.
    if (running) emit({ _tag: "Exit", exit: { exitCode: 0, signal: null } });
  });
  const opened: OpenedTerminal = {
    terminalId,
    sessionId,
    pid: 4242,
    write,
    resize,
    attach: (listener) => {
      listeners.add(listener);
      return { scrollback, running, unsubscribe: () => listeners.delete(listener) };
    },
    pause,
    resume,
    close,
  };
  return { opened, emit, listenerCount: () => listeners.size, write, resize, pause, resume, close };
}

function makeTerminalGateway() {
  const openCalls: Array<{ sessionId: string; cwd: string; cols?: number; rows?: number }> = [];
  const terminals: FakeTerminal[] = [];
  let nextId = 1;
  const gateway: TerminalGateway = {
    open: async (options) => {
      openCalls.push({
        sessionId: options.sessionId,
        cwd: options.cwd,
        cols: options.cols,
        rows: options.rows,
      });
      const terminal = makeFakeTerminal(`term-${nextId++}`, options.sessionId);
      terminals.push(terminal);
      return terminal.opened;
    },
    closeAll: async () => {
      await Promise.all(terminals.map((terminal) => terminal.opened.close()));
    },
  };
  return { gateway, openCalls, terminals };
}

// --- Fake script runner gateway (Slice 15a): scripted runs, no child procs ---

interface FakeScript {
  readonly opened: OpenedScript;
  /** Simulate output/server/exit reaching the connection's listener (+ scrollback). */
  emit: (event: ScriptEvent) => void;
  listenerCount: () => number;
  close: ReturnType<typeof vi.fn>;
}

function makeFakeScript(runId: string, sessionId: string, scriptName: string): FakeScript {
  const listeners = new Set<(event: ScriptEvent) => void>();
  let scrollback = "";
  let running = true;
  let discovered: DiscoveredServer | null = null;
  const emit = (event: ScriptEvent): void => {
    if (event._tag === "Output") scrollback += event.data;
    else if (event._tag === "Server") discovered = event.server;
    else running = false;
    for (const listener of [...listeners]) listener(event);
  };
  const close = vi.fn(async () => {
    if (running) emit({ _tag: "Exit", exit: { exitCode: 0, signal: "SIGTERM" } });
  });
  const opened: OpenedScript = {
    runId,
    sessionId,
    scriptName,
    pid: 5252,
    attach: (listener) => {
      listeners.add(listener);
      return {
        scrollback,
        running,
        server: discovered,
        unsubscribe: () => listeners.delete(listener),
      };
    },
    close,
  };
  return { opened, emit, listenerCount: () => listeners.size, close };
}

function makeScriptGateway(scripts: Record<string, { name: string; command: string }[]> = {}) {
  const startCalls: Array<{ sessionId: string; scriptName: string; cwd: string }> = [];
  const runs: FakeScript[] = [];
  let nextId = 1;
  let startError: Error | null = null;
  const gateway: ScriptRunnerGateway = {
    listScripts: async (cwd) => scripts[cwd] ?? [],
    start: async (options) => {
      startCalls.push({ ...options });
      if (startError) throw startError;
      const run = makeFakeScript(`run-${nextId++}`, options.sessionId, options.scriptName);
      runs.push(run);
      return run.opened;
    },
    closeAll: async () => {
      await Promise.all(runs.map((run) => run.opened.close()));
    },
  };
  return {
    gateway,
    startCalls,
    runs,
    setStartError: (error: Error | null) => {
      startError = error;
    },
  };
}

function makeManager(sessions: Record<string, ManagedSession>, list: unknown[] = []) {
  return {
    get: (id: string) => sessions[id],
    list: () => list,
  } as unknown as SessionManager;
}

// --- Fake diff gateway (Slice 9): scripted changed-file sets, no git ---

function makeDiffGateway() {
  const calls: Array<{ op: string; sessionId: string; cwd: string; path?: string }> = [];
  const set = {
    repo: true,
    files: [{ path: "src/a.ts", status: "M" as const, insertions: 3, deletions: 1, binary: false }],
    truncated: false,
  };
  const gateway: DiffGateway = {
    listFiles: async (sessionId, cwd) => {
      calls.push({ op: "listFiles", sessionId, cwd });
      return set;
    },
    refresh: async (sessionId, cwd) => {
      calls.push({ op: "refresh", sessionId, cwd });
      return { set, changed: true };
    },
    fileDiff: async (sessionId, cwd, path) => {
      calls.push({ op: "fileDiff", sessionId, cwd, path });
      return { path, diff: `diff --git a/${path} b/${path}\n`, truncated: false, binary: false };
    },
    drop: () => {},
  };
  return { gateway, calls, set };
}

// --- Fake editor launcher (Slice 11): scripted detection, recorded opens ---

function makeEditorLauncher() {
  const openCalls: Array<EditorOpenInput> = [];
  const launcher: EditorLauncher = {
    listEditors: async () => ["vscode", "zed"],
    open: async (input) => {
      openCalls.push(input);
    },
  };
  return { launcher, openCalls };
}

// --- Fake file service (Slice 13a): scripted listings/reads, no filesystem ---

function makeFileService() {
  const calls: Array<{ op: string; cwd: string; path?: string }> = [];
  const listResult = {
    path: "src",
    entries: [
      { name: "lib", kind: "dir" as const, size: null },
      { name: "a.ts", kind: "file" as const, size: 42 },
    ],
    truncated: false,
  };
  const service: FileService = {
    listDirectory: async (cwd, path) => {
      calls.push({ op: "listDirectory", cwd, path });
      return listResult;
    },
    readFile: async (cwd, path) => {
      calls.push({ op: "readFile", cwd, path });
      return { contentKind: "text", content: `// ${path}\n`, byteLength: 8, truncated: false };
    },
  };
  return { service, calls, listResult };
}

function harness(
  manager: SessionManager,
  terminals?: TerminalGateway,
  bufferedAmount?: () => number,
  diffs?: DiffGateway,
  editors?: EditorLauncher,
  files?: FileService,
  scripts?: ScriptRunnerGateway,
) {
  const frames: Frame[] = [];
  const conn = createRpcConnection({
    sessions: manager,
    terminals: terminals ?? makeTerminalGateway().gateway,
    diffs: diffs ?? makeDiffGateway().gateway,
    editors: editors ?? makeEditorLauncher().launcher,
    files: files ?? makeFileService().service,
    scripts: scripts ?? makeScriptGateway().gateway,
    send: (frame) => {
      // Assert every outbound frame is contract-valid.
      expect(decodeFrame(frame)._tag, JSON.stringify(frame)).toBe("Right");
      frames.push(frame);
    },
    ...(bufferedAmount ? { bufferedAmount } : {}),
  });
  return { conn, frames };
}

const frame = (id: number, request: unknown) => JSON.stringify({ id, request });

describe("createRpcConnection", () => {
  it("hello replies hello_ok with the session list", async () => {
    const list = [{ id: "s1", cwd: "/tmp", createdAt: "2026-01-01T00:00:00.000Z" }];
    const { conn, frames } = harness(makeManager({}, list));
    await conn.handleMessage(frame(7, { type: "hello" }));
    expect(frames).toEqual([{ kind: "hello_ok", id: 7, sessions: list }]);
  });

  it("unknown session replies with an error", async () => {
    const { conn, frames } = harness(makeManager({}));
    await conn.handleMessage(frame(1, { type: "abort", sessionId: "nope" }));
    expect(frames).toEqual([{ kind: "reply", id: 1, ok: false, error: "unknown session" }]);
  });

  it("subscribe_session with no lastSeq pushes a snapshot then acks", async () => {
    const { session } = makeSession("s1", { snapshot: { seq: 5, state: { cells: ["x"] } } });
    const { conn, frames } = harness(makeManager({ s1: session }));
    await conn.handleMessage(frame(2, { type: "subscribe_session", sessionId: "s1" }));
    expect(frames).toEqual([
      {
        kind: "push",
        message: { type: "snapshot", sessionId: "s1", seq: 5, state: { cells: ["x"] } },
      },
      { kind: "reply", id: 2, ok: true },
    ]);
  });

  it("subscribe_session with lastSeq replays from the ring (no snapshot)", async () => {
    const replay: StampedEvent[] = [
      { seq: 3, event: { kind: "text_delta" } as unknown as StampedEvent["event"] },
      { seq: 4, event: { kind: "text_delta" } as unknown as StampedEvent["event"] },
    ];
    const { session } = makeSession("s1", { replay });
    const { conn, frames } = harness(makeManager({ s1: session }));
    await conn.handleMessage(frame(3, { type: "subscribe_session", sessionId: "s1", lastSeq: 2 }));
    expect(frames.map((f) => (f.kind === "push" ? f.message.type : f.kind))).toEqual([
      "event",
      "event",
      "reply",
    ]);
    expect(frames[0]).toMatchObject({ kind: "push", message: { seq: 3 } });
    expect(frames[1]).toMatchObject({ kind: "push", message: { seq: 4 } });
  });

  it("subscribe_session with an evicted lastSeq falls back to a snapshot", async () => {
    const { session } = makeSession("s1", { replay: null, snapshot: { seq: 9, state: {} } });
    const { conn, frames } = harness(makeManager({ s1: session }));
    await conn.handleMessage(frame(4, { type: "subscribe_session", sessionId: "s1", lastSeq: 1 }));
    expect(frames[0]).toMatchObject({ kind: "push", message: { type: "snapshot", seq: 9 } });
    expect(frames[1]).toEqual({ kind: "reply", id: 4, ok: true });
  });

  it("live bus events after subscribe are pushed as frames", async () => {
    const { session, bus } = makeSession("s1");
    const { conn, frames } = harness(makeManager({ s1: session }));
    await conn.handleMessage(frame(5, { type: "subscribe_session", sessionId: "s1" }));
    frames.length = 0;
    bus.emit({ seq: 11, event: { kind: "text_delta" } as unknown as StampedEvent["event"] });
    expect(frames).toEqual([
      {
        kind: "push",
        message: { type: "event", sessionId: "s1", seq: 11, event: { kind: "text_delta" } },
      },
    ]);
  });

  it("re-subscribing replaces the old subscription", async () => {
    const { session, unsubscribe } = makeSession("s1");
    const { conn } = harness(makeManager({ s1: session }));
    await conn.handleMessage(frame(1, { type: "subscribe_session", sessionId: "s1" }));
    expect(unsubscribe).not.toHaveBeenCalled();
    await conn.handleMessage(frame(2, { type: "subscribe_session", sessionId: "s1" }));
    expect(unsubscribe).toHaveBeenCalledTimes(1);
  });

  it("close() releases all subscriptions", async () => {
    const { session, unsubscribe } = makeSession("s1");
    const { conn } = harness(makeManager({ s1: session }));
    await conn.handleMessage(frame(1, { type: "subscribe_session", sessionId: "s1" }));
    conn.close();
    expect(unsubscribe).toHaveBeenCalledTimes(1);
  });

  it("abort invokes the op and acks", async () => {
    const { session, ops } = makeSession("s1");
    const { conn, frames } = harness(makeManager({ s1: session }));
    await conn.handleMessage(frame(6, { type: "abort", sessionId: "s1" }));
    expect(ops.abort).toHaveBeenCalledTimes(1);
    expect(frames).toEqual([{ kind: "reply", id: 6, ok: true }]);
  });

  it("prompt forwards message + images and acks", async () => {
    const { session, ops } = makeSession("s1");
    const { conn, frames } = harness(makeManager({ s1: session }));
    const images = [{ type: "image", data: "aGk=", mimeType: "image/png" }];
    await conn.handleMessage(frame(1, { type: "prompt", sessionId: "s1", message: "hi", images }));
    expect(ops.prompt).toHaveBeenCalledWith("hi", images);
    expect(frames).toEqual([{ kind: "reply", id: 1, ok: true }]);
  });

  it("set_model rejects a model pi does not offer", async () => {
    const { session, ops } = makeSession("s1");
    const { conn, frames } = harness(makeManager({ s1: session }));
    await conn.handleMessage(
      frame(1, { type: "set_model", sessionId: "s1", provider: "openai", modelId: "gpt" }),
    );
    expect(ops.setModel).not.toHaveBeenCalled();
    expect(frames).toEqual([
      { kind: "reply", id: 1, ok: false, error: "unknown model: openai/gpt" },
    ]);
  });

  it("an op that throws yields an error reply", async () => {
    const { session, ops } = makeSession("s1");
    ops.abort.mockRejectedValueOnce(new Error("boom"));
    const { conn, frames } = harness(makeManager({ s1: session }));
    await conn.handleMessage(frame(1, { type: "abort", sessionId: "s1" }));
    expect(frames).toEqual([{ kind: "reply", id: 1, ok: false, error: "Error: boom" }]);
  });

  it("a malformed frame is rejected at the boundary with a best-effort id", async () => {
    const { conn, frames } = harness(makeManager({}));
    // valid id, but the request fails ClientMessage decode
    await conn.handleMessage(frame(8, { type: "nonsense" }));
    expect(frames).toEqual([{ kind: "reply", id: 8, ok: false, error: "invalid message" }]);
  });

  it("ui_response with an exotic (Date-like) payload is rejected by the contract", async () => {
    const { session, ops } = makeSession("s1");
    const { conn, frames } = harness(makeManager({ s1: session }));
    // A JSON array is not a plain object → PlainJsonRecord rejects it.
    await conn.handleMessage(frame(9, { type: "ui_response", sessionId: "s1", response: [] }));
    expect(ops.respondToUiRequest).not.toHaveBeenCalled();
    expect(frames).toEqual([{ kind: "reply", id: 9, ok: false, error: "invalid message" }]);
  });

  it("non-JSON input yields an invalid-JSON reply", async () => {
    const { conn, frames } = harness(makeManager({}));
    await conn.handleMessage("}{ not json");
    expect(frames).toEqual([{ kind: "reply", id: 0, ok: false, error: "invalid JSON" }]);
  });
});

describe("createRpcConnection terminal ops (Slice 8a)", () => {
  it("terminal_open spawns in the session's cwd and replies terminal_open_ok", async () => {
    const { session } = makeSession("s1");
    const { gateway, openCalls, terminals } = makeTerminalGateway();
    const { conn, frames } = harness(makeManager({ s1: session }), gateway);

    await conn.handleMessage(
      frame(1, { type: "terminal_open", sessionId: "s1", cols: 100, rows: 40 }),
    );
    // cwd came from the session server-side, never from the wire.
    expect(openCalls).toEqual([{ sessionId: "s1", cwd: "/tmp", cols: 100, rows: 40 }]);
    expect(frames).toEqual([
      { kind: "terminal_open_ok", id: 1, terminalId: "term-1", scrollback: "", running: true },
    ]);

    // PTY output flows as terminal_push frames on this connection.
    frames.length = 0;
    terminals[0]!.emit({ _tag: "Output", data: "hi\r\n" });
    expect(frames).toEqual([
      {
        kind: "terminal_push",
        message: { type: "terminal_output", terminalId: "term-1", data: "hi\r\n" },
      },
    ]);
  });

  it("terminal_open on an unknown session errors without spawning", async () => {
    const { gateway, openCalls } = makeTerminalGateway();
    const { conn, frames } = harness(makeManager({}), gateway);
    await conn.handleMessage(frame(2, { type: "terminal_open", sessionId: "nope" }));
    expect(openCalls).toEqual([]);
    expect(frames).toEqual([{ kind: "reply", id: 2, ok: false, error: "unknown session" }]);
  });

  it("terminal_input and terminal_resize route to the owning terminal and ack", async () => {
    const { session } = makeSession("s1");
    const { gateway, terminals } = makeTerminalGateway();
    const { conn, frames } = harness(makeManager({ s1: session }), gateway);
    await conn.handleMessage(frame(1, { type: "terminal_open", sessionId: "s1" }));
    frames.length = 0;

    await conn.handleMessage(
      frame(2, { type: "terminal_input", terminalId: "term-1", data: "ls\r" }),
    );
    expect(terminals[0]!.write).toHaveBeenCalledWith("ls\r");
    await conn.handleMessage(
      frame(3, { type: "terminal_resize", terminalId: "term-1", cols: 80, rows: 24 }),
    );
    expect(terminals[0]!.resize).toHaveBeenCalledWith(80, 24);
    expect(frames).toEqual([
      { kind: "reply", id: 2, ok: true },
      { kind: "reply", id: 3, ok: true },
    ]);
  });

  it("terminal ops against an unknown terminal error", async () => {
    const { conn, frames } = harness(makeManager({}));
    await conn.handleMessage(frame(4, { type: "terminal_input", terminalId: "term-9", data: "x" }));
    expect(frames).toEqual([{ kind: "reply", id: 4, ok: false, error: "unknown terminal" }]);
  });

  it("a failing write yields an error reply", async () => {
    const { session } = makeSession("s1");
    const { gateway, terminals } = makeTerminalGateway();
    const { conn, frames } = harness(makeManager({ s1: session }), gateway);
    await conn.handleMessage(frame(1, { type: "terminal_open", sessionId: "s1" }));
    frames.length = 0;
    terminals[0]!.write.mockRejectedValueOnce(new Error("terminal already exited"));
    await conn.handleMessage(frame(2, { type: "terminal_input", terminalId: "term-1", data: "x" }));
    expect(frames).toEqual([
      { kind: "reply", id: 2, ok: false, error: "Error: terminal already exited" },
    ]);
  });

  it("terminal_close tears the PTY down and the exit push still reaches the client", async () => {
    const { session } = makeSession("s1");
    const { gateway, terminals } = makeTerminalGateway();
    const { conn, frames } = harness(makeManager({ s1: session }), gateway);
    await conn.handleMessage(frame(1, { type: "terminal_open", sessionId: "s1" }));
    frames.length = 0;

    await conn.handleMessage(frame(2, { type: "terminal_close", terminalId: "term-1" }));
    expect(terminals[0]!.close).toHaveBeenCalledTimes(1);
    // The kill-produced exit event is pushed BEFORE the ack (listener stays
    // attached through the close), and the terminal is gone afterwards.
    expect(frames).toEqual([
      {
        kind: "terminal_push",
        message: { type: "terminal_exit", terminalId: "term-1", exitCode: 0, signal: null },
      },
      { kind: "reply", id: 2, ok: true },
    ]);
    await conn.handleMessage(frame(3, { type: "terminal_input", terminalId: "term-1", data: "x" }));
    expect(frames.at(-1)).toEqual({ kind: "reply", id: 3, ok: false, error: "unknown terminal" });
  });

  it("terminal_open with a terminalId reattaches: scrollback replayed, listener replaced", async () => {
    const { session } = makeSession("s1");
    const { gateway, terminals } = makeTerminalGateway();
    const { conn, frames } = harness(makeManager({ s1: session }), gateway);
    await conn.handleMessage(frame(1, { type: "terminal_open", sessionId: "s1" }));
    terminals[0]!.emit({ _tag: "Output", data: "earlier output" });
    frames.length = 0;

    await conn.handleMessage(
      frame(2, { type: "terminal_open", sessionId: "s1", terminalId: "term-1" }),
    );
    expect(frames).toEqual([
      {
        kind: "terminal_open_ok",
        id: 2,
        terminalId: "term-1",
        scrollback: "earlier output",
        running: true,
      },
    ]);
    // The old push listener was replaced, not stacked: one listener, one push.
    expect(terminals[0]!.listenerCount()).toBe(1);
    frames.length = 0;
    terminals[0]!.emit({ _tag: "Output", data: "later" });
    expect(frames).toHaveLength(1);
  });

  it("reattach validates ownership: unknown id or wrong session errors", async () => {
    const { session: s1 } = makeSession("s1");
    const { session: s2 } = makeSession("s2");
    const { gateway } = makeTerminalGateway();
    const { conn, frames } = harness(makeManager({ s1, s2 }), gateway);
    await conn.handleMessage(frame(1, { type: "terminal_open", sessionId: "s1" }));
    frames.length = 0;

    await conn.handleMessage(
      frame(2, { type: "terminal_open", sessionId: "s1", terminalId: "term-9" }),
    );
    await conn.handleMessage(
      frame(3, { type: "terminal_open", sessionId: "s2", terminalId: "term-1" }),
    );
    expect(frames).toEqual([
      { kind: "reply", id: 2, ok: false, error: "unknown terminal" },
      { kind: "reply", id: 3, ok: false, error: "unknown terminal" },
    ]);
  });

  it("connection close tears every owned terminal down without pushing to the dead socket", async () => {
    const { session } = makeSession("s1");
    const { gateway, terminals } = makeTerminalGateway();
    const { conn, frames } = harness(makeManager({ s1: session }), gateway);
    await conn.handleMessage(frame(1, { type: "terminal_open", sessionId: "s1" }));
    await conn.handleMessage(frame(2, { type: "terminal_open", sessionId: "s1" }));
    frames.length = 0;

    conn.close();
    expect(terminals[0]!.close).toHaveBeenCalledTimes(1);
    expect(terminals[1]!.close).toHaveBeenCalledTimes(1);
    // Listeners were detached BEFORE the kill: no frames to a dropped socket.
    expect(frames).toEqual([]);
  });

  it("the owning session's exit tears down that session's terminals only", async () => {
    const { session: s1, triggerExit } = makeSession("s1");
    const { session: s2 } = makeSession("s2");
    const { gateway, terminals } = makeTerminalGateway();
    const { conn, frames } = harness(makeManager({ s1, s2 }), gateway);
    await conn.handleMessage(frame(1, { type: "terminal_open", sessionId: "s1" }));
    await conn.handleMessage(frame(2, { type: "terminal_open", sessionId: "s2" }));
    frames.length = 0;

    triggerExit();
    expect(terminals[0]!.close).toHaveBeenCalledTimes(1);
    expect(terminals[1]!.close).not.toHaveBeenCalled();
    // The kill-produced exit push for the torn-down terminal reached the client.
    expect(frames).toEqual([
      {
        kind: "terminal_push",
        message: { type: "terminal_exit", terminalId: "term-1", exitCode: 0, signal: null },
      },
    ]);
    // s2's terminal is still usable.
    await conn.handleMessage(frame(3, { type: "terminal_input", terminalId: "term-2", data: "x" }));
    expect(frames.at(-1)).toEqual({ kind: "reply", id: 3, ok: true });
  });

  it("terminal_open on an ENDED (still-listed) session is rejected without spawning", async () => {
    const { session } = makeSession("s1", { endedAt: "2026-01-02T00:00:00.000Z" });
    const { gateway, openCalls } = makeTerminalGateway();
    const { conn, frames } = harness(makeManager({ s1: session }), gateway);

    await conn.handleMessage(frame(1, { type: "terminal_open", sessionId: "s1" }));
    // No shell was spawned-and-killed, and the client gets the truth.
    expect(openCalls).toEqual([]);
    expect(frames).toEqual([{ kind: "reply", id: 1, ok: false, error: "session has ended" }]);
  });

  it("a session that exits DURING the spawn yields an error, a reaped PTY, and no stale hook", async () => {
    // meta not yet marked ended (the guard passes), but onExit fires
    // immediately — the session died between sessions.get() and the spawn.
    const { session, exitUnhook } = makeSession("s1", { exitImmediately: true });
    const { gateway, terminals } = makeTerminalGateway();
    const { conn, frames } = harness(makeManager({ s1: session }), gateway);

    await conn.handleMessage(frame(1, { type: "terminal_open", sessionId: "s1" }));
    // The freshly spawned PTY was reaped by the exit hook…
    expect(terminals[0]!.close).toHaveBeenCalledTimes(1);
    // …the immediately-fired hook was unhooked, not left stale in the map…
    expect(exitUnhook).toHaveBeenCalledTimes(1);
    // …and the reply is an error, never `running: true` for a dead terminal.
    const reply = frames.find((f) => f.kind === "reply" || f.kind === "terminal_open_ok");
    expect(reply).toEqual({ kind: "reply", id: 1, ok: false, error: "session has ended" });
  });

  it("a socket buffer over the high-water mark pauses the PTY; drain resumes it", async () => {
    vi.useFakeTimers();
    try {
      const { session } = makeSession("s1");
      const { gateway, terminals } = makeTerminalGateway();
      let buffered = 0;
      const { conn } = harness(makeManager({ s1: session }), gateway, () => buffered);
      await conn.handleMessage(frame(1, { type: "terminal_open", sessionId: "s1" }));

      // Below the mark: output flows, no pause.
      terminals[0]!.emit({ _tag: "Output", data: "ok" });
      expect(terminals[0]!.pause).not.toHaveBeenCalled();

      // The socket backs up: the producing PTY is paused exactly once.
      buffered = 2_000_000;
      terminals[0]!.emit({ _tag: "Output", data: "flood" });
      terminals[0]!.emit({ _tag: "Output", data: "flood" });
      expect(terminals[0]!.pause).toHaveBeenCalledTimes(1);
      expect(terminals[0]!.resume).not.toHaveBeenCalled();

      // Still above the resume mark: the poller keeps waiting.
      await vi.advanceTimersByTimeAsync(200);
      expect(terminals[0]!.resume).not.toHaveBeenCalled();

      // Buffer drains below the low-water mark: the poller resumes the PTY.
      buffered = 1_000;
      await vi.advanceTimersByTimeAsync(100);
      expect(terminals[0]!.resume).toHaveBeenCalledTimes(1);

      // A later flood pauses again (the valve re-arms).
      buffered = 2_000_000;
      terminals[0]!.emit({ _tag: "Output", data: "flood" });
      expect(terminals[0]!.pause).toHaveBeenCalledTimes(2);
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("createRpcConnection diff ops (Slice 9)", () => {
  it("diff_files answers diff_files_ok with the session's changed-file set", async () => {
    const { session } = makeSession("s1");
    const diffs = makeDiffGateway();
    const { conn, frames } = harness(
      makeManager({ s1: session }),
      undefined,
      undefined,
      diffs.gateway,
    );
    await conn.handleMessage(frame(1, { type: "diff_files", sessionId: "s1" }));
    expect(frames).toEqual([
      { kind: "diff_files_ok", id: 1, repo: true, files: diffs.set.files, truncated: false },
    ]);
    // The cwd is resolved server-side from the session's meta, never the wire.
    expect(diffs.calls).toEqual([{ op: "listFiles", sessionId: "s1", cwd: "/tmp" }]);
  });

  it("diff_file answers diff_file_ok with the bounded unified diff", async () => {
    const { session } = makeSession("s1");
    const diffs = makeDiffGateway();
    const { conn, frames } = harness(
      makeManager({ s1: session }),
      undefined,
      undefined,
      diffs.gateway,
    );
    await conn.handleMessage(frame(2, { type: "diff_file", sessionId: "s1", path: "src/a.ts" }));
    expect(frames).toEqual([
      {
        kind: "diff_file_ok",
        id: 2,
        path: "src/a.ts",
        diff: "diff --git a/src/a.ts b/src/a.ts\n",
        truncated: false,
        binary: false,
      },
    ]);
    expect(diffs.calls).toEqual([
      { op: "fileDiff", sessionId: "s1", cwd: "/tmp", path: "src/a.ts" },
    ]);
  });

  it("diff ops on an unknown session reply with an error (ownership gate)", async () => {
    const diffs = makeDiffGateway();
    const { conn, frames } = harness(makeManager({}), undefined, undefined, diffs.gateway);
    await conn.handleMessage(frame(3, { type: "diff_files", sessionId: "nope" }));
    await conn.handleMessage(frame(4, { type: "diff_file", sessionId: "nope", path: "a" }));
    expect(frames).toEqual([
      { kind: "reply", id: 3, ok: false, error: "unknown session" },
      { kind: "reply", id: 4, ok: false, error: "unknown session" },
    ]);
    expect(diffs.calls).toEqual([]);
  });

  it("a throwing diff gateway surfaces as a typed failure reply, not a crash", async () => {
    const { session } = makeSession("s1");
    const diffs = makeDiffGateway();
    const throwing: DiffGateway = {
      ...diffs.gateway,
      listFiles: async () => {
        throw new Error("git exploded");
      },
    };
    const { conn, frames } = harness(makeManager({ s1: session }), undefined, undefined, throwing);
    await conn.handleMessage(frame(5, { type: "diff_files", sessionId: "s1" }));
    expect(frames).toEqual([{ kind: "reply", id: 5, ok: false, error: "Error: git exploded" }]);
  });
});

describe("createRpcConnection editor ops (Slice 11)", () => {
  it("editors_list answers editors_ok with the server-detected list", async () => {
    const editors = makeEditorLauncher();
    const { conn, frames } = harness(
      makeManager({}),
      undefined,
      undefined,
      undefined,
      editors.launcher,
    );
    await conn.handleMessage(frame(1, { type: "editors_list" }));
    expect(frames).toEqual([{ kind: "editors_ok", id: 1, editors: ["vscode", "zed"] }]);
  });

  it("editor_open resolves the cwd from the session's meta and acks", async () => {
    const { session } = makeSession("s1");
    const editors = makeEditorLauncher();
    const { conn, frames } = harness(
      makeManager({ s1: session }),
      undefined,
      undefined,
      undefined,
      editors.launcher,
    );
    await conn.handleMessage(
      frame(2, {
        type: "editor_open",
        sessionId: "s1",
        path: "src/a.ts",
        line: 12,
        editor: "vscode",
      }),
    );
    expect(frames).toEqual([{ kind: "reply", id: 2, ok: true }]);
    // The cwd is server-side session meta — the wire only carried a RELATIVE
    // path and an editor ID (never a command string or an absolute path).
    expect(editors.openCalls).toEqual([
      { cwd: "/tmp", path: "src/a.ts", line: 12, editor: "vscode" },
    ]);
  });

  it("editor_open without a line omits the field entirely", async () => {
    const { session } = makeSession("s1");
    const editors = makeEditorLauncher();
    const { conn } = harness(
      makeManager({ s1: session }),
      undefined,
      undefined,
      undefined,
      editors.launcher,
    );
    await conn.handleMessage(
      frame(3, { type: "editor_open", sessionId: "s1", path: "src/a.ts", editor: "zed" }),
    );
    expect(editors.openCalls).toEqual([{ cwd: "/tmp", path: "src/a.ts", editor: "zed" }]);
  });

  it("editor_open on an unknown session replies with an error (never launches)", async () => {
    const editors = makeEditorLauncher();
    const { conn, frames } = harness(
      makeManager({}),
      undefined,
      undefined,
      undefined,
      editors.launcher,
    );
    await conn.handleMessage(
      frame(4, { type: "editor_open", sessionId: "nope", path: "src/a.ts", editor: "vscode" }),
    );
    expect(frames).toEqual([{ kind: "reply", id: 4, ok: false, error: "unknown session" }]);
    expect(editors.openCalls).toEqual([]);
  });

  it("a rejecting launcher (containment/unknown editor) surfaces as a failure reply", async () => {
    const { session } = makeSession("s1");
    const throwing: EditorLauncher = {
      listEditors: async () => [],
      open: async () => {
        throw new Error("path escapes the session directory");
      },
    };
    const { conn, frames } = harness(
      makeManager({ s1: session }),
      undefined,
      undefined,
      undefined,
      throwing,
    );
    await conn.handleMessage(
      frame(5, { type: "editor_open", sessionId: "s1", path: "src/a.ts", editor: "vscode" }),
    );
    expect(frames).toEqual([
      { kind: "reply", id: 5, ok: false, error: "path escapes the session directory" },
    ]);
  });
});

describe("createRpcConnection file ops (Slice 13a)", () => {
  const withFiles = (
    sessions: Record<string, ManagedSession>,
    files: FileService,
    list: unknown[] = [],
  ) => harness(makeManager(sessions, list), undefined, undefined, undefined, undefined, files);

  it("file_list answers file_list_ok, resolving the cwd from the session meta", async () => {
    const { session } = makeSession("s1");
    const files = makeFileService();
    const { conn, frames } = withFiles({ s1: session }, files.service);
    await conn.handleMessage(frame(1, { type: "file_list", sessionId: "s1", path: "src" }));
    expect(frames).toEqual([
      {
        kind: "file_list_ok",
        id: 1,
        path: "src",
        entries: files.listResult.entries,
        truncated: false,
      },
    ]);
    // The cwd is server-side session meta; the wire carried only a relative path.
    expect(files.calls).toEqual([{ op: "listDirectory", cwd: "/tmp", path: "src" }]);
  });

  it("file_list without a path lists the project root (path undefined)", async () => {
    const { session } = makeSession("s1");
    const files = makeFileService();
    const { conn } = withFiles({ s1: session }, files.service);
    await conn.handleMessage(frame(2, { type: "file_list", sessionId: "s1" }));
    expect(files.calls).toEqual([{ op: "listDirectory", cwd: "/tmp", path: undefined }]);
  });

  it("file_read answers file_read_ok with the bounded content", async () => {
    const { session } = makeSession("s1");
    const files = makeFileService();
    const { conn, frames } = withFiles({ s1: session }, files.service);
    await conn.handleMessage(frame(3, { type: "file_read", sessionId: "s1", path: "src/a.ts" }));
    expect(frames).toEqual([
      {
        kind: "file_read_ok",
        id: 3,
        path: "src/a.ts",
        contentKind: "text",
        content: "// src/a.ts\n",
        byteLength: 8,
        truncated: false,
      },
    ]);
    expect(files.calls).toEqual([{ op: "readFile", cwd: "/tmp", path: "src/a.ts" }]);
  });

  it("file ops on an unknown session reply with an error (ownership gate)", async () => {
    const files = makeFileService();
    const { conn, frames } = withFiles({}, files.service);
    await conn.handleMessage(frame(4, { type: "file_list", sessionId: "nope" }));
    await conn.handleMessage(frame(5, { type: "file_read", sessionId: "nope", path: "a.ts" }));
    expect(frames).toEqual([
      { kind: "reply", id: 4, ok: false, error: "unknown session" },
      { kind: "reply", id: 5, ok: false, error: "unknown session" },
    ]);
    expect(files.calls).toEqual([]);
  });

  it("a rejecting file service (containment) surfaces as a failure reply", async () => {
    const { session } = makeSession("s1");
    const throwing: FileService = {
      listDirectory: async () => {
        throw new Error("path escapes the session directory");
      },
      readFile: async () => {
        throw new Error("file not found");
      },
    };
    const { conn, frames } = withFiles({ s1: session }, throwing);
    await conn.handleMessage(frame(6, { type: "file_list", sessionId: "s1", path: "../etc" }));
    await conn.handleMessage(frame(7, { type: "file_read", sessionId: "s1", path: "missing" }));
    expect(frames).toEqual([
      { kind: "reply", id: 6, ok: false, error: "path escapes the session directory" },
      { kind: "reply", id: 7, ok: false, error: "file not found" },
    ]);
  });
});

describe("createRpcConnection script/dev-server ops (Slice 15a)", () => {
  const withScripts = (sessions: Record<string, ManagedSession>, scripts: ScriptRunnerGateway) =>
    harness(makeManager(sessions), undefined, undefined, undefined, undefined, undefined, scripts);

  const server: DiscoveredServer = { host: "localhost", port: 5173, url: "http://localhost:5173" };

  it("scripts_list answers with the session project's declared scripts (cwd from meta)", async () => {
    const { session } = makeSession("s1"); // meta.cwd === "/tmp"
    const scripts = makeScriptGateway({ "/tmp": [{ name: "dev", command: "vite" }] });
    const { conn, frames } = withScripts({ s1: session }, scripts.gateway);
    await conn.handleMessage(frame(1, { type: "scripts_list", sessionId: "s1" }));
    expect(frames).toEqual([
      { kind: "scripts_list_ok", id: 1, scripts: [{ name: "dev", command: "vite" }] },
    ]);
  });

  it("script_start spawns via the gateway, streams output/server, and pushes exit", async () => {
    const { session } = makeSession("s1");
    const scripts = makeScriptGateway();
    const { conn, frames } = withScripts({ s1: session }, scripts.gateway);
    await conn.handleMessage(
      frame(2, { type: "script_start", sessionId: "s1", scriptName: "dev" }),
    );
    // The gateway resolves the cwd server-side (session meta), never the wire.
    expect(scripts.startCalls).toEqual([{ sessionId: "s1", scriptName: "dev", cwd: "/tmp" }]);
    expect(frames).toEqual([
      { kind: "script_run_ok", id: 2, runId: "run-1", scrollback: "", running: true, server: null },
    ]);

    const run = scripts.runs[0]!;
    run.emit({ _tag: "Output", data: "vite ready\n" });
    run.emit({ _tag: "Server", server });
    run.emit({ _tag: "Exit", exit: { exitCode: 0, signal: null } });
    expect(frames.slice(1)).toEqual([
      {
        kind: "script_push",
        message: { type: "script_output", runId: "run-1", data: "vite ready\n" },
      },
      { kind: "script_push", message: { type: "script_server", runId: "run-1", server } },
      {
        kind: "script_push",
        message: { type: "script_exit", runId: "run-1", exitCode: 0, signal: null },
      },
    ]);
  });

  it("script_attach replays scrollback + current server and replaces the listener", async () => {
    const { session } = makeSession("s1");
    const scripts = makeScriptGateway();
    const { conn, frames } = withScripts({ s1: session }, scripts.gateway);
    await conn.handleMessage(
      frame(1, { type: "script_start", sessionId: "s1", scriptName: "dev" }),
    );
    const run = scripts.runs[0]!;
    run.emit({ _tag: "Output", data: "listening\n" });
    run.emit({ _tag: "Server", server });
    expect(run.listenerCount()).toBe(1);

    await conn.handleMessage(frame(2, { type: "script_attach", runId: "run-1" }));
    expect(frames.at(-1)).toEqual({
      kind: "script_run_ok",
      id: 2,
      runId: "run-1",
      scrollback: "listening\n",
      running: true,
      server,
    });
    // The old listener was replaced, not stacked (still exactly one).
    expect(run.listenerCount()).toBe(1);
  });

  it("script_stop closes the run (tree-kill via the scope) and acks", async () => {
    const { session } = makeSession("s1");
    const scripts = makeScriptGateway();
    const { conn, frames } = withScripts({ s1: session }, scripts.gateway);
    await conn.handleMessage(
      frame(1, { type: "script_start", sessionId: "s1", scriptName: "dev" }),
    );
    const run = scripts.runs[0]!;
    await conn.handleMessage(frame(2, { type: "script_stop", runId: "run-1" }));
    expect(run.close).toHaveBeenCalledTimes(1);
    expect(frames.at(-1)).toEqual({ kind: "reply", id: 2, ok: true });
  });

  it("script ops on an unknown session / run reply with an error (ownership gate)", async () => {
    const scripts = makeScriptGateway();
    const { conn, frames } = withScripts({}, scripts.gateway);
    await conn.handleMessage(frame(1, { type: "scripts_list", sessionId: "nope" }));
    await conn.handleMessage(
      frame(2, { type: "script_start", sessionId: "nope", scriptName: "dev" }),
    );
    await conn.handleMessage(frame(3, { type: "script_attach", runId: "run-99" }));
    await conn.handleMessage(frame(4, { type: "script_stop", runId: "run-99" }));
    expect(frames).toEqual([
      { kind: "reply", id: 1, ok: false, error: "unknown session" },
      { kind: "reply", id: 2, ok: false, error: "unknown session" },
      { kind: "reply", id: 3, ok: false, error: "unknown run" },
      { kind: "reply", id: 4, ok: false, error: "unknown run" },
    ]);
    expect(scripts.startCalls).toEqual([]);
  });

  it("script_start on an ended session is rejected without spawning", async () => {
    const { session } = makeSession("s1", { endedAt: "2026-01-01T00:00:00.000Z" });
    const scripts = makeScriptGateway();
    const { conn, frames } = withScripts({ s1: session }, scripts.gateway);
    await conn.handleMessage(
      frame(1, { type: "script_start", sessionId: "s1", scriptName: "dev" }),
    );
    expect(frames).toEqual([{ kind: "reply", id: 1, ok: false, error: "session has ended" }]);
    expect(scripts.startCalls).toEqual([]);
  });

  it("a rejected start (e.g. already running / not declared) surfaces as a failure reply", async () => {
    const { session } = makeSession("s1");
    const scripts = makeScriptGateway();
    scripts.setStartError(new Error("a script is already running for this session"));
    const { conn, frames } = withScripts({ s1: session }, scripts.gateway);
    await conn.handleMessage(
      frame(1, { type: "script_start", sessionId: "s1", scriptName: "dev" }),
    );
    expect(frames).toEqual([
      { kind: "reply", id: 1, ok: false, error: "a script is already running for this session" },
    ]);
  });

  it("a session exit tears down its running scripts (no orphan dev servers)", async () => {
    const { session, triggerExit } = makeSession("s1");
    const scripts = makeScriptGateway();
    const { conn } = withScripts({ s1: session }, scripts.gateway);
    await conn.handleMessage(
      frame(1, { type: "script_start", sessionId: "s1", scriptName: "dev" }),
    );
    const run = scripts.runs[0]!;
    triggerExit();
    expect(run.close).toHaveBeenCalledTimes(1);
  });

  it("connection close tears down every owned run", async () => {
    const { session } = makeSession("s1");
    const scripts = makeScriptGateway();
    const { conn } = withScripts({ s1: session }, scripts.gateway);
    await conn.handleMessage(
      frame(1, { type: "script_start", sessionId: "s1", scriptName: "dev" }),
    );
    const run = scripts.runs[0]!;
    conn.close();
    expect(run.close).toHaveBeenCalledTimes(1);
  });
});
