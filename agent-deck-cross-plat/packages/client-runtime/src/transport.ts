import {
  RpcClientFrame,
  RpcServerFrame,
  type ClientMessage,
  type ServerMessage,
  type SessionMeta,
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
  /** A frame that failed contracts decode at the boundary — dropped, reported. */
  readonly onDecodeError?: (error: string, raw: unknown) => void;
  readonly backoff?: BackoffOptions;
  /** Injectable reconnect scheduler (defaults to global setTimeout). */
  readonly setTimer?: (fn: () => void, ms: number) => TimerHandle;
  readonly clearTimer?: (handle: TimerHandle) => void;
}

interface Pending {
  readonly resolve: (sessions: SessionMeta[]) => void;
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
        this.pending.get(frame.id)?.resolve(frame.sessions);
        this.pending.delete(frame.id);
        return;
      }
      case "reply": {
        const entry = this.pending.get(frame.id);
        if (!entry) return;
        this.pending.delete(frame.id);
        if (frame.ok) entry.resolve([]);
        else entry.reject(new Error(frame.error));
        return;
      }
      case "push":
        this.options.onPush?.(frame.message);
        return;
    }
  }

  private rejectAllPending(error: Error): void {
    for (const entry of this.pending.values()) entry.reject(error);
    this.pending.clear();
  }

  /**
   * Send a request and resolve when its reply arrives. `hello` resolves with the
   * session list; every other op resolves with `[]` on ack and rejects on a
   * server failure reply. Rejects immediately if not connected.
   */
  request(message: ClientMessage): Promise<SessionMeta[]> {
    if (this.state !== "connected" || !this.socket) {
      return Promise.reject(new Error("transport not connected"));
    }
    const id = this.nextRequestId++;
    const frame: RpcClientFrame = { id, request: message };
    return new Promise<SessionMeta[]>((resolve, reject) => {
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
