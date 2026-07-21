import {
  RpcClientFrame,
  RpcServerFrame,
  type ClientMessage,
  type DiffClientRequest,
  type DiffFileEntry,
  type DiffPush,
  type EditorClientRequest,
  type EditorId,
  type ServerMessage,
  type SessionMeta,
  type TerminalClientRequest,
  type TerminalPush,
} from "@agent-deck/contracts";
import { Either, Schema } from "effect";

/**
 * The client half of the Slice-7 Effect-RPC-over-WebSocket transport — the
 * transport state machine the web app switches to in Slice 7b. It owns exactly
 * three concerns:
 *
 *   1. a connection state machine (connecting → connected → reconnecting …),
 *   2. reconnect with exponential backoff (reset on a successful open), and
 *   3. typed decode of every inbound frame through the contracts Effect Schema —
 *      a malformed push is REJECTED at the boundary (never surfaced as an event).
 *
 * It is framework-light on purpose (no Effect runtime, no zustand): the WebSocket
 * constructor and the reconnect timer are injected, so the machine is fully
 * deterministic under test, and the browser's `WebSocket` satisfies the
 * structural {@link WebSocketLike} contract at the 7b call site.
 */

// ---------------------------------------------------------------------------
// Injected primitives (structural, so we need no DOM lib and tests need no I/O)
// ---------------------------------------------------------------------------

/** The structural subset of `WebSocket` the transport uses. */
export interface WebSocketLike {
  send(data: string): void;
  close(): void;
  onopen: (() => void) | null;
  onmessage: ((event: { data: unknown }) => void) | null;
  onclose: (() => void) | null;
  onerror: (() => void) | null;
}

export type WebSocketCtor = new (url: string) => WebSocketLike;

/** An opaque reconnect-timer handle (a number in the browser/Node). */
export type TimerHandle = ReturnType<typeof setTimeout>;

export interface BackoffOptions {
  /** First reconnect delay, and the value reset to on a successful open. */
  readonly initialMs: number;
  /** The delay ceiling. */
  readonly maxMs: number;
  /** Multiplier applied after each failed attempt. */
  readonly factor: number;
}

export const DEFAULT_BACKOFF: BackoffOptions = { initialMs: 500, maxMs: 10_000, factor: 2 };

// ---------------------------------------------------------------------------
// State machine
// ---------------------------------------------------------------------------

export type ConnectionState = "idle" | "connecting" | "connected" | "reconnecting" | "closed";

export interface TransportOptions {
  readonly url: string;
  readonly webSocketCtor: WebSocketCtor;
  /** Every state transition (including no-op re-entries are suppressed). */
  readonly onState?: (state: ConnectionState) => void;
  /** Fired once per (re)connection, after the socket opens — the consumer
   * (re)subscribes here. */
  readonly onConnected?: () => void;
  /** A decoded, schema-valid server push (event/snapshot/meta/exit/…). */
  readonly onPush?: (message: ServerMessage) => void;
  /** A decoded terminal push (Slice 8b): output chunks + the exit notification. */
  readonly onTerminalPush?: (message: TerminalPush) => void;
  /** A decoded diff push (Slice 10): a session's refreshed changed-file set. */
  readonly onDiffPush?: (message: DiffPush) => void;
  /** A frame that failed contracts decode at the boundary — dropped, reported. */
  readonly onDecodeError?: (error: string, raw: unknown) => void;
  readonly backoff?: BackoffOptions;
  /** Injectable reconnect scheduler (defaults to global setTimeout). */
  readonly setTimer?: (fn: () => void, ms: number) => TimerHandle;
  readonly clearTimer?: (handle: TimerHandle) => void;
}

/** The reply to a `terminal_open` request (Slice 8b): the server-allocated id
 * plus — on reattach — the replayed scrollback and whether the PTY still runs. */
export interface TerminalOpenResult {
  readonly terminalId: string;
  readonly scrollback: string;
  readonly running: boolean;
}

/** The reply to a `diff_files` request (Slice 10): the session's changed-file
 * set, with the non-git answer expressed as `repo: false` + an empty set. */
export interface DiffFilesResult {
  readonly repo: boolean;
  readonly files: readonly DiffFileEntry[];
  readonly truncated: boolean;
}

/** The reply to a `diff_file` request (Slice 10): one file's bounded unified
 * diff (empty for binary files / paths outside the changed set). */
export interface DiffFileResult {
  readonly path: string;
  readonly diff: string;
  readonly truncated: boolean;
  readonly binary: boolean;
}

/** How one request settled: a plain ack, the hello session list, or a
 * terminal/diff/editor reply payload. Internal — the public methods narrow it. */
type RequestSettled =
  | { readonly kind: "ok" }
  | { readonly kind: "sessions"; readonly sessions: SessionMeta[] }
  | { readonly kind: "terminal_open"; readonly result: TerminalOpenResult }
  | { readonly kind: "diff_files"; readonly result: DiffFilesResult }
  | { readonly kind: "diff_file"; readonly result: DiffFileResult }
  | { readonly kind: "editors"; readonly editors: readonly EditorId[] };

interface Pending {
  readonly resolve: (settled: RequestSettled) => void;
  readonly reject: (error: Error) => void;
}

const decodeServerFrame = Schema.decodeUnknownEither(RpcServerFrame);

export class RpcTransport {
  private state: ConnectionState = "idle";
  private socket: WebSocketLike | null = null;
  private nextRequestId = 1;
  private readonly pending = new Map<number, Pending>();
  private currentBackoffMs: number;
  private reconnectTimer: TimerHandle | null = null;
  /** Bumped on connect()/close() so a stale socket's callbacks are ignored. */
  private generation = 0;
  private closedByUser = false;

  private readonly backoff: BackoffOptions;
  private readonly setTimer: (fn: () => void, ms: number) => TimerHandle;
  private readonly clearTimer: (handle: TimerHandle) => void;

  constructor(private readonly options: TransportOptions) {
    this.backoff = options.backoff ?? DEFAULT_BACKOFF;
    this.currentBackoffMs = this.backoff.initialMs;
    this.setTimer = options.setTimer ?? ((fn, ms) => setTimeout(fn, ms));
    this.clearTimer = options.clearTimer ?? ((handle) => clearTimeout(handle));
  }

  /** The current connection state. */
  getState(): ConnectionState {
    return this.state;
  }

  /** The delay the NEXT reconnect attempt will wait (exposed for tests/telemetry). */
  getBackoffMs(): number {
    return this.currentBackoffMs;
  }

  private setState(next: ConnectionState): void {
    if (this.state === next) return;
    this.state = next;
    this.options.onState?.(next);
  }

  /** Open the connection (idempotent while already live). */
  connect(): void {
    if (this.state === "connecting" || this.state === "connected") return;
    // A caller-driven connect during backoff supersedes the pending retry:
    // left armed, the stale timer would fire after this openSocket() and open
    // a SECOND socket — bumping the generation so the first stays live but
    // orphaned, streaming a duplicate server-side subscription.
    if (this.reconnectTimer !== null) {
      this.clearTimer(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.closedByUser = false;
    this.openSocket();
  }

  private openSocket(): void {
    const myGeneration = ++this.generation;
    this.setState("connecting");
    const socket = new this.options.webSocketCtor(this.options.url);
    this.socket = socket;

    socket.onopen = () => {
      if (myGeneration !== this.generation) return;
      this.currentBackoffMs = this.backoff.initialMs; // reset backoff on success
      this.setState("connected");
      this.options.onConnected?.();
    };
    socket.onmessage = (event) => {
      if (myGeneration !== this.generation) return;
      this.handleRaw(event.data);
    };
    socket.onclose = () => {
      if (myGeneration !== this.generation) return;
      this.socket = null;
      this.rejectAllPending(new Error("transport disconnected"));
      if (this.closedByUser) {
        this.setState("closed");
        return;
      }
      this.setState("reconnecting");
      this.scheduleReconnect();
    };
    socket.onerror = () => {
      // Errors are surfaced as a subsequent close; nothing to do here beyond
      // letting the close handler drive reconnect.
    };
  }

  private scheduleReconnect(): void {
    const delay = this.currentBackoffMs;
    // Advance the backoff for the attempt AFTER this one.
    this.currentBackoffMs = Math.min(
      this.currentBackoffMs * this.backoff.factor,
      this.backoff.maxMs,
    );
    this.reconnectTimer = this.setTimer(() => {
      this.reconnectTimer = null;
      if (this.closedByUser) return;
      this.openSocket();
    }, delay);
  }

  private handleRaw(data: unknown): void {
    let parsed: unknown;
    try {
      parsed = JSON.parse(typeof data === "string" ? data : String(data));
    } catch (error) {
      this.options.onDecodeError?.(`invalid JSON: ${String(error)}`, data);
      return;
    }
    const decoded = decodeServerFrame(parsed);
    if (Either.isLeft(decoded)) {
      this.options.onDecodeError?.("frame failed contract decode", parsed);
      return;
    }
    const frame = decoded.right;
    switch (frame.kind) {
      case "hello_ok": {
        this.pending.get(frame.id)?.resolve({ kind: "sessions", sessions: frame.sessions });
        this.pending.delete(frame.id);
        return;
      }
      case "reply": {
        const entry = this.pending.get(frame.id);
        if (!entry) return;
        this.pending.delete(frame.id);
        if (frame.ok) entry.resolve({ kind: "ok" });
        else entry.reject(new Error(frame.error));
        return;
      }
      case "terminal_open_ok": {
        const entry = this.pending.get(frame.id);
        if (!entry) return;
        this.pending.delete(frame.id);
        entry.resolve({
          kind: "terminal_open",
          result: {
            terminalId: frame.terminalId,
            scrollback: frame.scrollback,
            running: frame.running,
          },
        });
        return;
      }
      case "diff_files_ok": {
        const entry = this.pending.get(frame.id);
        if (!entry) return;
        this.pending.delete(frame.id);
        entry.resolve({
          kind: "diff_files",
          result: { repo: frame.repo, files: frame.files, truncated: frame.truncated },
        });
        return;
      }
      case "diff_file_ok": {
        const entry = this.pending.get(frame.id);
        if (!entry) return;
        this.pending.delete(frame.id);
        entry.resolve({
          kind: "diff_file",
          result: {
            path: frame.path,
            diff: frame.diff,
            truncated: frame.truncated,
            binary: frame.binary,
          },
        });
        return;
      }
      case "editors_ok": {
        const entry = this.pending.get(frame.id);
        if (!entry) return;
        this.pending.delete(frame.id);
        entry.resolve({ kind: "editors", editors: frame.editors });
        return;
      }
      case "push":
        this.options.onPush?.(frame.message);
        return;
      case "terminal_push":
        this.options.onTerminalPush?.(frame.message);
        return;
      case "diff_push":
        this.options.onDiffPush?.(frame.message);
        return;
    }
  }

  private rejectAllPending(error: Error): void {
    for (const entry of this.pending.values()) entry.reject(error);
    this.pending.clear();
  }

  /** Send one frame and settle on its correlated reply (shared by the typed
   * request methods below). Rejects immediately if not connected. */
  private sendRequest(
    request: ClientMessage | TerminalClientRequest | DiffClientRequest | EditorClientRequest,
  ): Promise<RequestSettled> {
    if (this.state !== "connected" || !this.socket) {
      return Promise.reject(new Error("transport not connected"));
    }
    const id = this.nextRequestId++;
    const frame: RpcClientFrame = { id, request };
    return new Promise<RequestSettled>((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      try {
        // Encode through the contract so an ill-formed request is caught here
        // rather than silently rejected server-side.
        this.socket?.send(JSON.stringify(Schema.encodeSync(RpcClientFrame)(frame)));
      } catch (error) {
        this.pending.delete(id);
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  /**
   * Send a request and resolve when its reply arrives. `hello` resolves with the
   * session list; every other op resolves with `[]` on ack and rejects on a
   * server failure reply. Rejects immediately if not connected.
   */
  async request(message: ClientMessage): Promise<SessionMeta[]> {
    const settled = await this.sendRequest(message);
    return settled.kind === "sessions" ? settled.sessions : [];
  }

  /**
   * Open (or, with `terminalId`, reattach to) a session terminal (Slice 8b).
   * Resolves with the server-allocated id + replayed scrollback; rejects on a
   * server failure reply (unknown session/terminal, spawn failure).
   */
  async openTerminal(request: {
    sessionId: string;
    terminalId?: string;
    cols?: number;
    rows?: number;
  }): Promise<TerminalOpenResult> {
    const settled = await this.sendRequest({ type: "terminal_open", ...request });
    if (settled.kind !== "terminal_open") {
      throw new Error("terminal_open settled without a terminal_open_ok reply");
    }
    return settled.result;
  }

  /** Send a terminal input/resize/close op; resolves on ack, rejects on error. */
  async terminalRequest(
    message: Exclude<TerminalClientRequest, { type: "terminal_open" }>,
  ): Promise<void> {
    await this.sendRequest(message);
  }

  /**
   * Fetch a session's changed-file set (Slice 10). Resolves with the bounded
   * set (`repo: false` + empty for non-git sessions); rejects on a server
   * failure reply (unknown session) or while disconnected.
   */
  async diffFiles(sessionId: string): Promise<DiffFilesResult> {
    const settled = await this.sendRequest({ type: "diff_files", sessionId });
    if (settled.kind !== "diff_files") {
      throw new Error("diff_files settled without a diff_files_ok reply");
    }
    return settled.result;
  }

  /**
   * Fetch one changed file's bounded unified diff (Slice 10). A path outside
   * the session's changed set (or a binary file) resolves with an empty diff.
   */
  async diffFile(sessionId: string, path: string): Promise<DiffFileResult> {
    const settled = await this.sendRequest({ type: "diff_file", sessionId, path });
    if (settled.kind !== "diff_file") {
      throw new Error("diff_file settled without a diff_file_ok reply");
    }
    return settled.result;
  }

  /**
   * List the editors detected on the server's machine (Slice 11). The server
   * caches its probe; editors not installed simply don't appear.
   */
  async listEditors(): Promise<readonly EditorId[]> {
    const settled = await this.sendRequest({ type: "editors_list" });
    if (settled.kind !== "editors") {
      throw new Error("editors_list settled without an editors_ok reply");
    }
    return settled.editors;
  }

  /**
   * Open one changed file (optionally at a 1-based line) in a detected editor
   * (Slice 11). Resolves on ack; rejects on a server failure reply (unknown
   * session/editor, path outside the session's cwd, missing file).
   */
  async openInEditor(request: {
    sessionId: string;
    path: string;
    line?: number;
    editor: EditorId;
  }): Promise<void> {
    await this.sendRequest({ type: "editor_open", ...request });
  }

  /** Convenience: the `hello` handshake, resolving with the session list. */
  hello(): Promise<SessionMeta[]> {
    return this.request({ type: "hello" });
  }

  /** Deliberately close: no reconnect, pending rejected, state → closed. */
  close(): void {
    this.closedByUser = true;
    this.generation++;
    if (this.reconnectTimer !== null) {
      this.clearTimer(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    const socket = this.socket;
    this.socket = null;
    this.rejectAllPending(new Error("transport closed"));
    if (socket) socket.close();
    this.setState("closed");
  }
}
