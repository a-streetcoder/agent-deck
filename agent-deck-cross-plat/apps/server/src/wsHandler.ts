import type { IncomingMessage } from "node:http";
import { clientMessageSchema, type ServerMessage } from "@agent-deck/domain";
import type { FastifyInstance } from "fastify";
import { WebSocketServer, type WebSocket } from "ws";
import type { ManagedSession, SessionManager } from "./SessionManager.ts";

export interface WebSocketLayer {
  wss: WebSocketServer;
  /** Push a server message to every connected client. */
  broadcast: (message: ServerMessage) => void;
}

/**
 * The WebSocket layer: socket accept (with the local-origin guard),
 * per-session subscribe/replay, and client-message dispatch. Moved verbatim
 * from server.ts (Slice 2 decomposition).
 */
export function setupWebSocket(deps: {
  fastify: FastifyInstance;
  sessions: SessionManager;
}): WebSocketLayer {
  const { fastify, sessions } = deps;

  // WebSocket: live domain-event push + session commands.
  const wss = new WebSocketServer({ noServer: true });
  const clients = new Set<WebSocket>();

  const send = (socket: WebSocket, message: ServerMessage): void => {
    if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(message));
  };

  const broadcast = (message: ServerMessage): void => {
    for (const client of clients) send(client, message);
  };

  // Per-socket subscription bookkeeping: re-subscribing to the same session
  // replaces the old subscription (no duplicate events), and every listener —
  // bus subscriber AND session exit listener — is released on socket close.
  const socketCleanups = new Map<WebSocket, Map<string, () => void>>();

  const subscribe = (socket: WebSocket, session: ManagedSession, lastSeq?: number): void => {
    const cleanups = socketCleanups.get(socket) ?? new Map<string, () => void>();
    socketCleanups.set(socket, cleanups);
    cleanups.get(session.meta.id)?.();

    const unsubscribeBus = session.bus.subscribe(({ seq, event }) => {
      send(socket, { type: "event", sessionId: session.meta.id, seq, event });
    });
    const unsubscribeExit = session.onExit((exit) =>
      send(socket, {
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

    if (lastSeq !== undefined) {
      const replay = session.bus.replayFrom(lastSeq);
      if (replay) {
        for (const { seq, event } of replay) {
          send(socket, { type: "event", sessionId: session.meta.id, seq, event });
        }
        return;
      }
    }
    const { seq, state } = session.snapshot();
    send(socket, { type: "snapshot", sessionId: session.meta.id, seq, state });
  };

  wss.on("connection", (socket: WebSocket) => {
    clients.add(socket);
    socket.on("close", () => {
      clients.delete(socket);
      const cleanups = socketCleanups.get(socket);
      socketCleanups.delete(socket);
      if (cleanups) for (const cleanup of cleanups.values()) cleanup();
    });
    socket.on("message", (raw: Buffer) => {
      void (async () => {
        let message;
        try {
          message = clientMessageSchema.parse(JSON.parse(raw.toString("utf8")));
        } catch (error) {
          send(socket, { type: "error", message: `invalid message: ${String(error)}` });
          return;
        }
        if (message.type === "hello") {
          send(socket, { type: "hello_ok", sessions: sessions.list() });
          return;
        }
        const session = sessions.get(message.sessionId);
        if (!session) {
          send(socket, {
            type: "error",
            message: "unknown session",
            sessionId: message.sessionId,
          });
          return;
        }
        try {
          switch (message.type) {
            case "subscribe_session":
              subscribe(socket, session, message.lastSeq);
              break;
            case "prompt":
              await session.prompt(message.message, message.images);
              break;
            case "steer":
              await session.steer(message.message);
              break;
            case "follow_up":
              await session.followUp(message.message);
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
                (m) => m.provider === message.provider && m.id === message.modelId,
              );
              if (!known) {
                send(socket, {
                  type: "error",
                  message: `unknown model: ${message.provider}/${message.modelId}`,
                  sessionId: message.sessionId,
                });
                break;
              }
              await session.setModel(message.provider, message.modelId);
              break;
            }
            case "set_thinking":
              await session.setThinkingLevel(message.level);
              break;
            case "ui_response":
              session.respondToUiRequest(message.response);
              break;
          }
        } catch (error) {
          send(socket, {
            type: "error",
            message: String(error),
            sessionId: message.sessionId,
          });
        }
      })();
    });
  });

  // Browsers may open cross-origin WebSockets to localhost services; only
  // accept upgrades from local origins (or non-browser clients, which send
  // no Origin header) so a hostile web page can't drive sessions.
  const isTrustedOrigin = (origin: string | undefined): boolean => {
    if (origin === undefined) return true; // ws library clients, curl, tests
    try {
      const { hostname } = new URL(origin);
      return hostname === "127.0.0.1" || hostname === "localhost" || hostname === "::1";
    } catch {
      return false;
    }
  };

  fastify.server.on("upgrade", (request: IncomingMessage, socket, head) => {
    if (request.url !== "/ws" || !isTrustedOrigin(request.headers.origin)) {
      socket.destroy();
      return;
    }
    wss.handleUpgrade(request, socket, head, (ws) => wss.emit("connection", ws, request));
  });

  return { wss, broadcast };
}
