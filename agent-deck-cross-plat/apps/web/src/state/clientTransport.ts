import {
  RpcTransport,
  type ConnectionState,
  type TerminalOpenResult,
  type WebSocketCtor,
} from "@agent-deck/client-runtime";
import { RPC_WS_PATH } from "@agent-deck/contracts";
import type {
  ClientMessage,
  ServerMessage,
  TerminalClientRequest,
  TerminalPush,
} from "@agent-deck/contracts";
import type { ConnectionStatus } from "./store.ts";

/**
 * The client-side socket transport, factored behind one interface so wsBridge.ts
 * wires the store/reducer independently of the framing. Since Slice 7c the sole
 * implementation is the Effect-RPC `/rpc` transport (the legacy `/ws` envelope
 * was retired); the interface remains so the reducer wiring stays framing-agnostic.
 *
 * The transport owns this contract:
 *   - `connect(sessionId)` (re)connects subscribed to exactly that session,
 *     replacing any prior connection ("one socket, one subscribed session at a
 *     time"), and drives the store connection status through {@link TransportHost}.
 *   - on (re)open it resubscribes with the current `lastSeq` so the server
 *     replays the gap (or snapshots when the ring evicted it).
 *   - `send(message)` is fire-and-forget; a command sent while disconnected is
 *     dropped silently (the reconnect will re-sync).
 */

/** The shared wiring both transports call back into (store + reducer bridge). */
export interface TransportHost {
  /** Feed one decoded server message into the domain reducer / store. */
  onServerMessage(message: ServerMessage): void;
  /** Reflect the connection state into the store (drives the status banner). */
  setConnection(status: ConnectionStatus): void;
  /** The last applied seq — sent on (re)subscribe so the server replays the gap. */
  getLastSeq(): number;
  /** A terminal push (Slice 8b): output chunks + exit, outside the reducer path. */
  onTerminalPush?(message: TerminalPush): void;
}

export interface ClientTransport {
  connect(sessionId: string): void;
  send(message: ClientMessage): void;
  /** Open (or reattach `terminalId` to) the session terminal; rejects offline. */
  openTerminal(request: {
    sessionId: string;
    terminalId?: string;
    cols?: number;
    rows?: number;
  }): Promise<TerminalOpenResult>;
  /** Fire-and-forget terminal input/resize/close (dropped while disconnected,
   * like {@link send} — the drawer resyncs via reattach on reconnect). */
  sendTerminal(message: Exclude<TerminalClientRequest, { type: "terminal_open" }>): void;
}

function socketUrl(pathSuffix: string): string {
  const proto = location.protocol === "https:" ? "wss" : "ws";
  return `${proto}://${location.host}${pathSuffix}`;
}

// ---------------------------------------------------------------------------
// `/rpc` transport — the Effect-RPC state machine from client-runtime.
// ---------------------------------------------------------------------------

/** Map the transport's 5-state machine onto the store's 3-status banner:
 * `connected` → "open"; the pre-open states → "connecting"; a drop/close →
 * "closed" (shown briefly before the transport retries). */
function toConnectionStatus(state: ConnectionState): ConnectionStatus {
  switch (state) {
    case "connected":
      return "open";
    case "idle":
    case "connecting":
      return "connecting";
    case "reconnecting":
    case "closed":
      return "closed";
  }
}

export class RpcClientTransport implements ClientTransport {
  private transport: RpcTransport | null = null;
  private currentSessionId: string | null = null;
  private generation = 0;

  constructor(private readonly host: TransportHost) {}

  connect(sessionId: string): void {
    const myGeneration = ++this.generation;
    this.currentSessionId = sessionId;
    this.transport?.close();
    this.host.setConnection("connecting");

    const transport: RpcTransport = new RpcTransport({
      url: socketUrl(RPC_WS_PATH),
      // The browser WebSocket satisfies the structural WebSocketLike contract.
      webSocketCtor: WebSocket as unknown as WebSocketCtor,
      onState: (state) => {
        if (myGeneration !== this.generation) return;
        this.host.setConnection(toConnectionStatus(state));
      },
      onConnected: () => {
        if (myGeneration !== this.generation) return;
        // Resubscribe on every (re)connection with the current lastSeq — the
        // server replays the gap from the ring, or snapshots when it evicted it.
        const lastSeq = this.host.getLastSeq();
        void transport
          .request({
            type: "subscribe_session",
            sessionId,
            lastSeq: lastSeq > 0 ? lastSeq : undefined,
          })
          .catch((error: unknown) => {
            // A genuine subscribe failure (e.g. unknown session) surfaces like
            // legacy's error push; a disconnect-driven rejection does not.
            if (myGeneration !== this.generation) return;
            if (transport.getState() !== "connected") return;
            this.host.onServerMessage({ type: "error", message: String(error), sessionId });
          });
      },
      onPush: (message) => {
        if (myGeneration !== this.generation) return;
        this.host.onServerMessage(message);
      },
      onTerminalPush: (message) => {
        if (myGeneration !== this.generation) return;
        this.host.onTerminalPush?.(message);
      },
      onDecodeError: (error, raw) => {
        // A push that fails the contract at the boundary is dropped (never
        // surfaced as an event). Log for diagnosis; do not disturb UI state.
        console.warn("[rpc] dropped malformed frame:", error, raw);
      },
    });
    this.transport = transport;
    transport.connect();
  }

  send(message: ClientMessage): void {
    const transport = this.transport;
    // Fire-and-forget: a command sent while disconnected is dropped silently
    // (legacy parity — the reconnect resyncs), so we never reject-spam the banner.
    if (!transport || transport.getState() !== "connected") return;
    void transport.request(message).catch((error: unknown) => {
      // Only surface a genuine server error REPLY (arrives while still
      // connected); a rejection from a mid-flight disconnect is suppressed —
      // legacy shows no error there, just the reconnect banner.
      if (transport !== this.transport) return;
      if (transport.getState() !== "connected") return;
      this.host.onServerMessage({
        type: "error",
        message: String(error),
        sessionId: this.currentSessionId ?? undefined,
      });
    });
  }

  openTerminal(request: {
    sessionId: string;
    terminalId?: string;
    cols?: number;
    rows?: number;
  }): Promise<TerminalOpenResult> {
    const transport = this.transport;
    if (!transport || transport.getState() !== "connected") {
      return Promise.reject(new Error("transport not connected"));
    }
    return transport.openTerminal(request);
  }

  sendTerminal(message: Exclude<TerminalClientRequest, { type: "terminal_open" }>): void {
    const transport = this.transport;
    // Fire-and-forget, mirroring send(): while disconnected the op is dropped —
    // a disconnect kills the server-side terminal anyway (the connection owns
    // it), and the drawer reopens/reattaches once the transport is back.
    if (!transport || transport.getState() !== "connected") return;
    void transport.terminalRequest(message).catch(() => {
      // Failures here (e.g. input to an exited terminal) are surfaced to the
      // drawer through the terminal_exit push, not the error banner.
    });
  }
}
