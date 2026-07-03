import type { IncomingMessage } from "node:http";
import { clientMessageSchema, type ServerMessage } from "@agent-deck/domain";
import Fastify, { type FastifyInstance } from "fastify";
import { WebSocketServer, type WebSocket } from "ws";
import { z } from "zod";
import { SessionIndex } from "./persistence.ts";
import { ReceiptBus } from "./receipts.ts";
import { SessionManager, type ManagedSession } from "./SessionManager.ts";

const createSessionBody = z.object({
  cwd: z.string(),
  provider: z.string().optional(),
  model: z.string().optional(),
  extensions: z.array(z.string()).optional(),
  skills: z.array(z.string()).optional(),
  /** Extra env for the pi subprocess (tests use this for a hermetic HOME). */
  env: z.record(z.string()).optional(),
});

export interface AgentDeckServer {
  fastify: FastifyInstance;
  port: number;
  sessions: SessionManager;
  receipts: ReceiptBus;
  close(): Promise<void>;
}

export interface StartServerOptions {
  port?: number;
  host?: string;
  dataDir?: string;
}

export async function startServer(options: StartServerOptions = {}): Promise<AgentDeckServer> {
  const receipts = new ReceiptBus(process.env.AGENT_DECK_TEST === "1");
  const sessions = new SessionManager(receipts);
  const index = new SessionIndex(options.dataDir);
  const fastify = Fastify({ logger: false });

  fastify.get("/health", async () => ({ ok: true }));

  fastify.get("/sessions", async () => ({ sessions: sessions.list() }));

  fastify.post("/sessions", async (request, reply) => {
    const parsed = createSessionBody.safeParse(request.body);
    if (!parsed.success) {
      return reply.status(400).send({ error: parsed.error.message });
    }
    const body = parsed.data;
    const session = sessions.create({
      cwd: body.cwd,
      env: body.env,
      plan: {
        kind: "parent",
        provider: body.provider,
        model: body.model,
        extensions: body.extensions,
        skills: body.skills,
      },
    });
    index.upsert(session.meta);
    return reply.status(201).send({ session: session.meta });
  });

  // WebSocket: live domain-event push + session commands.
  const wss = new WebSocketServer({ noServer: true });

  const send = (socket: WebSocket, message: ServerMessage): void => {
    if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(message));
  };

  const subscribe = (socket: WebSocket, session: ManagedSession, lastSeq?: number): void => {
    const unsubscribe = session.bus.subscribe(({ seq, event }) => {
      send(socket, { type: "event", sessionId: session.meta.id, seq, event });
    });
    socket.on("close", unsubscribe);

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
              session.onExit((exit) =>
                send(socket, {
                  type: "session_exit",
                  sessionId: session.meta.id,
                  code: exit.code,
                  signal: exit.signal,
                }),
              );
              break;
            case "prompt":
              await session.prompt(message.message);
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

  fastify.server.on("upgrade", (request: IncomingMessage, socket, head) => {
    if (request.url === "/ws") {
      wss.handleUpgrade(request, socket, head, (ws) => wss.emit("connection", ws, request));
    } else {
      socket.destroy();
    }
  });

  await fastify.listen({ port: options.port ?? 0, host: options.host ?? "127.0.0.1" });
  const address = fastify.server.address();
  const port = typeof address === "object" && address !== null ? address.port : 0;

  return {
    fastify,
    port,
    sessions,
    receipts,
    close: async () => {
      await sessions.stopAll();
      wss.close();
      await fastify.close();
    },
  };
}
