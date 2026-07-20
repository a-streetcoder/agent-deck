import { RpcClientFrame, type RpcServerFrame, type ServerMessage } from "@agent-deck/contracts";
import { Either, Schema } from "effect";
import { WebSocketServer, type WebSocket } from "ws";
import type { ManagedSession, SessionManager } from "./SessionManager.ts";

/**
 * The Effect-RPC-over-WebSocket endpoint (Slice 7), mounted on `/rpc` by
 * wsHandler.ts as the sole socket transport (the legacy `/ws` envelope was
 * retired in Slice 7c). It shares the `SessionManager` facade — which resolves
 * the pi subprocess + push bus through the server's ManagedRuntime (runtime.ts
 * services: sessionManager, pushBus) — and reuses the same seq/replay/snapshot
 * primitives (`session.bus.subscribe` / `session.bus.replayFrom` /
 * `session.snapshot()`) that the transport has always exposed; only the framing
 * is RPC.
 *
 * Wire (see @agent-deck/contracts `rpc.ts`):
 *   - client → server: `RpcClientFrame` = `{ id, request: ClientMessage }`,
 *     decoded (and thus runtime-VALIDATED) here through the contracts Effect
 *     Schema — this is where contracts is the runtime validator.
 *   - server → client: `RpcServerFrame` union — an id-correlated `reply` /
 *     `hello_ok`, or an unsolicited `push` wrapping a bare `ServerMessage`.
 *
 * The per-connection protocol lives in {@link createRpcConnection}, decoupled
 * from `ws` so it is unit-testable with a plain `send` collector.
 */

const decodeClientFrame = Schema.decodeUnknownEither(RpcClientFrame);

/** One RPC connection's protocol: message dispatch + subscription cleanup,
 * independent of the socket transport. */
export interface RpcConnection {
  /** Dispatch one raw client frame (JSON text). Resolves after any async op. */
  handleMessage: (raw: string) => Promise<void>;
  /** Release every per-session subscription this connection holds. */
  close: () => void;
}

export function createRpcConnection(deps: {
  sessions: SessionManager;
  send: (frame: RpcServerFrame) => void;
}): RpcConnection {
  const { sessions, send } = deps;
  const push = (message: ServerMessage): void => send({ kind: "push", message });

  // Per-connection subscription bookkeeping: re-subscribing to a session
  // replaces its old subscription, and every listener is released on close.
  const cleanups = new Map<string, () => void>();

  const subscribe = (session: ManagedSession, lastSeq?: number): void => {
    cleanups.get(session.meta.id)?.();

    const unsubscribeBus = session.bus.subscribe(({ seq, event }) => {
      push({ type: "event", sessionId: session.meta.id, seq, event });
    });
    const unsubscribeExit = session.onExit((exit) =>
      push({
        type: "session_exit",
        sessionId: session.meta.id,
        code: exit.code,
        signal: exit.signal,
      }),
    );
    cleanups.set(session.meta.id, () => {
      unsubscribeBus();
      unsubscribeExit();
    });

    // seq/replay/snapshot semantics: subscribe with lastSeq → replay from the
    // ring, or snapshot when the ring has evicted that seq.
    if (lastSeq !== undefined) {
      const replay = session.bus.replayFrom(lastSeq);
      if (replay) {
        for (const { seq, event } of replay) {
          push({ type: "event", sessionId: session.meta.id, seq, event });
        }
        return;
      }
    }
    const { seq, state } = session.snapshot();
    push({ type: "snapshot", sessionId: session.meta.id, seq, state });
  };

  const handleMessage = async (raw: string): Promise<void> => {
    // Best-effort id extraction so a decode failure can still be correlated to
    // the request that produced it.
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      send({ kind: "reply", id: 0, ok: false, error: "invalid JSON" });
      return;
    }
    const rawId =
      typeof parsed === "object" &&
      parsed !== null &&
      typeof (parsed as { id?: unknown }).id === "number"
        ? (parsed as { id: number }).id
        : 0;
    const id = Number.isInteger(rawId) && rawId >= 0 ? rawId : 0;

    const decoded = decodeClientFrame(parsed);
    if (Either.isLeft(decoded)) {
      send({ kind: "reply", id, ok: false, error: "invalid message" });
      return;
    }
    const { request } = decoded.right;
    const replyOk = (): void => send({ kind: "reply", id, ok: true });
    const replyError = (message: string): void =>
      send({ kind: "reply", id, ok: false, error: message });

    if (request.type === "hello") {
      send({ kind: "hello_ok", id, sessions: sessions.list() });
      return;
    }
    const session = sessions.get(request.sessionId);
    if (!session) {
      replyError("unknown session");
      return;
    }
    try {
      switch (request.type) {
        case "subscribe_session":
          subscribe(session, request.lastSeq);
          break;
        case "prompt":
          await session.prompt(request.message, request.images);
          break;
        case "steer":
          await session.steer(request.message);
          break;
        case "follow_up":
          await session.followUp(request.message);
          break;
        case "abort":
          await session.abort();
          break;
        case "compact":
          await session.compact();
          break;
        case "set_model": {
          // Only switch to models pi actually offers.
          const available = await session.getAvailableModels();
          const known = available.some(
            (m) => m.provider === request.provider && m.id === request.modelId,
          );
          if (!known) {
            replyError(`unknown model: ${request.provider}/${request.modelId}`);
            return;
          }
          await session.setModel(request.provider, request.modelId);
          break;
        }
        case "set_thinking":
          await session.setThinkingLevel(request.level);
          break;
        case "ui_response":
          session.respondToUiRequest(request.response);
          break;
      }
      replyOk();
    } catch (error) {
      replyError(String(error));
    }
  };

  return {
    handleMessage,
    close: () => {
      for (const cleanup of cleanups.values()) cleanup();
      cleanups.clear();
    },
  };
}

export interface RpcEndpoint {
  wss: WebSocketServer;
  /** Push a server message to every connected RPC client (wrapped as a frame). */
  broadcast: (message: ServerMessage) => void;
}

export function setupRpcEndpoint(deps: { sessions: SessionManager }): RpcEndpoint {
  const { sessions } = deps;

  const wss = new WebSocketServer({ noServer: true });
  const clients = new Set<WebSocket>();

  const sendTo = (socket: WebSocket, frame: RpcServerFrame): void => {
    if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(frame));
  };
  const broadcast = (message: ServerMessage): void => {
    for (const client of clients) sendTo(client, { kind: "push", message });
  };

  wss.on("connection", (socket: WebSocket) => {
    clients.add(socket);
    const connection = createRpcConnection({
      sessions,
      send: (frame) => sendTo(socket, frame),
    });
    socket.on("close", () => {
      clients.delete(socket);
      connection.close();
    });
    socket.on("message", (raw: Buffer) => {
      void connection.handleMessage(raw.toString("utf8"));
    });
  });

  return { wss, broadcast };
}
