import type { IncomingMessage } from "node:http";
import { RPC_WS_PATH } from "@agent-deck/contracts";
import type { ServerMessage } from "@agent-deck/contracts";
import type { FastifyInstance } from "fastify";
import { setupRpcEndpoint } from "./rpcHandler.ts";
import type { SessionManager } from "./SessionManager.ts";
import type { TerminalGateway } from "./terminalGateway.ts";

export interface WebSocketLayer {
  /** Push a server message to every connected RPC client (wrapped as a frame). */
  broadcast: (message: ServerMessage) => void;
  /** Close the `/rpc` socket server. */
  close: () => void;
}

/**
 * The WebSocket layer: socket-upgrade accept (with the local-origin guard) routed
 * to the Effect-RPC endpoint on `/rpc` (rpcHandler.ts). The legacy bare-envelope
 * `/ws` path was retired in Slice 7c — `/rpc` is now the only transport, and the
 * contracts Effect Schema is the sole runtime validator at the socket boundary.
 */
export function setupWebSocket(deps: {
  fastify: FastifyInstance;
  sessions: SessionManager;
  terminals: TerminalGateway;
}): WebSocketLayer {
  const { fastify, sessions, terminals } = deps;

  // The Effect-RPC endpoint (rpcHandler.ts): per-connection frame dispatch,
  // subscribe/replay, and broadcast — all sharing the SessionManager facade.
  const rpc = setupRpcEndpoint({ sessions, terminals });

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
    if (!isTrustedOrigin(request.headers.origin)) {
      socket.destroy();
      return;
    }
    // Only `/rpc` (the Effect-RPC frames) is accepted; anything else is rejected.
    if (request.url === RPC_WS_PATH) {
      rpc.wss.handleUpgrade(request, socket, head, (ws) => rpc.wss.emit("connection", ws, request));
    } else {
      socket.destroy();
    }
  });

  return {
    broadcast: rpc.broadcast,
    close: () => {
      // `wss.close()` with `noServer: true` does NOT destroy accepted client
      // sockets — it only waits for them to leave. Terminate them so every
      // connection's 'close' handler (subscription + terminal teardown in
      // rpcHandler) runs deterministically during server shutdown instead of
      // whenever the remote peer decides to hang up.
      for (const client of rpc.wss.clients) client.terminate();
      rpc.wss.close();
    },
  };
}
