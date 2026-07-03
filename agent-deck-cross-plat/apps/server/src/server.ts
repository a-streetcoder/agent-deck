import { randomUUID } from "node:crypto";
import { existsSync, statSync } from "node:fs";
import type { IncomingMessage } from "node:http";
import { homedir } from "node:os";
import nodePath from "node:path";
import { clientMessageSchema, type ProjectMeta, type ServerMessage } from "@agent-deck/domain";
import {
  ensureDirs,
  projectWatchDirs,
  scanAgents,
  scanSkills,
  watchResources,
  type ResourceRoots,
} from "@agent-deck/resources";
import fastifyStatic from "@fastify/static";
import Fastify, { type FastifyInstance } from "fastify";
import { WebSocketServer, type WebSocket } from "ws";
import { z } from "zod";
import { ProjectIndex, SessionIndex } from "./persistence.ts";
import { ReceiptBus } from "./receipts.ts";
import {
  SessionManager,
  type AgentSessionPlan,
  type LaunchPlan,
  type ManagedSession,
} from "./SessionManager.ts";

const createProjectBody = z.object({
  path: z.string(),
  name: z.string().optional(),
});

const createSessionBody = z.object({
  cwd: z.string().optional(),
  projectId: z.string().optional(),
  /** Launch an agent-backed session: inject this agent's system prompt/tools/skills. */
  agentName: z.string().optional(),
  provider: z.string().optional(),
  model: z.string().optional(),
  extensions: z.array(z.string()).optional(),
  skills: z.array(z.string()).optional(),
  /** Extra env for the pi subprocess (tests use this for a hermetic HOME). */
  env: z.record(z.string()).optional(),
});

/** Tools only bridge extensions provide — stripped until those bridges are ported (M2). */
const BRIDGE_ONLY_TOOLS = new Set(["contact_supervisor", "managed_subagent", "ask_user"]);

const THINKING_LEVELS = new Set(["off", "minimal", "low", "medium", "high", "xhigh"]);

function asThinkingLevel(value: string | undefined): AgentSessionPlan["thinking"] {
  return value && THINKING_LEVELS.has(value) ? (value as AgentSessionPlan["thinking"]) : undefined;
}

/**
 * Session defaults from the server environment. The e2e harness (and any dev
 * setup) uses these to route UI-created sessions to the mock provider without
 * the UI knowing: AGENT_DECK_DEFAULT_PROVIDER, AGENT_DECK_DEFAULT_MODEL,
 * AGENT_DECK_DEFAULT_EXTENSIONS (path.delimiter-separated),
 * AGENT_DECK_PI_ENV (JSON object merged into the pi subprocess env).
 */
function envDefaults(): {
  provider?: string;
  model?: string;
  extensions?: string[];
  env?: Record<string, string>;
} {
  const extensions = process.env.AGENT_DECK_DEFAULT_EXTENSIONS?.split(nodePath.delimiter).filter(
    Boolean,
  );
  let env: Record<string, string> | undefined;
  if (process.env.AGENT_DECK_PI_ENV) {
    try {
      env = JSON.parse(process.env.AGENT_DECK_PI_ENV) as Record<string, string>;
    } catch {
      // Malformed JSON — ignore rather than break session creation.
    }
  }
  return {
    provider: process.env.AGENT_DECK_DEFAULT_PROVIDER,
    model: process.env.AGENT_DECK_DEFAULT_MODEL,
    extensions: extensions?.length ? extensions : undefined,
    env,
  };
}

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
  /** Serve a built web app (apps/web/dist) at /. */
  staticDir?: string;
}

export async function startServer(options: StartServerOptions = {}): Promise<AgentDeckServer> {
  const receipts = new ReceiptBus(process.env.AGENT_DECK_TEST === "1");
  const index = new SessionIndex(options.dataDir);
  const sessions = new SessionManager(receipts, (meta) => index.upsert(meta));
  const projects = new ProjectIndex(options.dataDir);
  const fastify = Fastify({ logger: false });

  if (options.staticDir) {
    await fastify.register(fastifyStatic, { root: options.staticDir });
  }

  fastify.get("/health", async () => ({ ok: true }));

  // Resource scanning. `home` follows the pi subprocess HOME override (set via
  // AGENT_DECK_PI_ENV in tests) so the scanner and pi see the same catalogs.
  const resourceHome = (): string => {
    const piEnv = envDefaults().env;
    return piEnv?.HOME ?? homedir();
  };
  const rootsFor = (projectId?: string): ResourceRoots => ({
    home: resourceHome(),
    projectPath: projectId ? projects.find((p) => p.id === projectId)?.path : undefined,
  });

  fastify.get("/resources/agents", async (request) => {
    const { projectId } = request.query as { projectId?: string };
    return { agents: scanAgents(rootsFor(projectId)) };
  });

  fastify.get("/resources/skills", async (request) => {
    const { projectId } = request.query as { projectId?: string };
    return { skills: scanSkills(rootsFor(projectId)) };
  });

  fastify.get("/projects", async () => ({ projects: projects.list() }));

  fastify.post("/projects", async (request, reply) => {
    const parsed = createProjectBody.safeParse(request.body);
    if (!parsed.success) {
      return reply.status(400).send({ error: parsed.error.message });
    }
    const projectPath = nodePath.resolve(parsed.data.path);
    if (!existsSync(projectPath) || !statSync(projectPath).isDirectory()) {
      return reply.status(400).send({ error: `not a directory: ${projectPath}` });
    }
    // Idempotent by path: re-adding an existing project returns it.
    const existing = projects.find((p) => p.path === projectPath);
    if (existing) return reply.status(200).send({ project: existing });
    const project: ProjectMeta = {
      id: randomUUID(),
      path: projectPath,
      name: parsed.data.name ?? nodePath.basename(projectPath),
      createdAt: new Date().toISOString(),
    };
    projects.upsert(project);
    watchProject(project.path);
    return reply.status(201).send({ project });
  });

  fastify.get("/sessions", async (request) => {
    const { projectId } = request.query as { projectId?: string };
    const all = sessions.list();
    return { sessions: projectId ? all.filter((s) => s.projectId === projectId) : all };
  });

  fastify.post("/sessions", async (request, reply) => {
    const parsed = createSessionBody.safeParse(request.body);
    if (!parsed.success) {
      return reply.status(400).send({ error: parsed.error.message });
    }
    const body = parsed.data;
    const defaults = envDefaults();
    let cwd = body.cwd ?? process.cwd();
    if (body.projectId) {
      const project = projects.find((p) => p.id === body.projectId);
      if (!project) return reply.status(404).send({ error: "unknown project" });
      cwd = project.path;
    }

    const provider = body.provider ?? defaults.provider;
    const model = body.model ?? defaults.model;
    const extensions = body.extensions ?? defaults.extensions;

    // CONTRACT GAP (pi-rpc-launch-flags.md §1): full parent launches also load
    // the Agent Deck bridge/audit/web extensions, preserve the active
    // APPEND_SYSTEM.md, and pass Default+Project skill/prompt assignments.
    // Assignments land in slice 10; bridge extensions are M2.
    let plan: LaunchPlan = {
      kind: "parent",
      provider,
      model,
      extensions,
      skills: body.skills,
    };

    if (body.agentName) {
      // Agent-backed session: the picked agent's body becomes the system
      // prompt; frontmatter tools/skills/model apply per the launch contract.
      const roots = rootsFor(body.projectId);
      const agent = scanAgents(roots).find((a) => a.name === body.agentName && !a.shadowed);
      if (!agent) return reply.status(404).send({ error: `unknown agent: ${body.agentName}` });
      const skillsByName = new Map(scanSkills(roots).map((s) => [s.name, s]));
      const agentSkillPaths = (agent.skills ?? [])
        .map((name) => skillsByName.get(name)?.baseDir)
        .filter((p): p is string => Boolean(p));
      const effectiveTools = agent.tools?.filter((tool) => !BRIDGE_ONLY_TOOLS.has(tool));
      plan = {
        kind: "agent",
        systemPrompt: { mode: agent.systemPromptMode, text: agent.body },
        tools: effectiveTools,
        extensions: [...(extensions ?? []), ...(agent.extensions ?? [])],
        skills: agentSkillPaths,
        provider,
        // Agent model, else the inherited default; frontmatter thinking applies
        // either way (suffix when a model is known, --thinking otherwise).
        model: agent.model ?? model,
        thinking: asThinkingLevel(agent.thinking),
      };
    }

    const session = sessions.create({
      cwd,
      projectId: body.projectId,
      agentName: body.agentName,
      env: { ...defaults.env, ...body.env },
      plan,
    });
    index.upsert(session.meta);
    return reply.status(201).send({ session: session.meta });
  });

  // WebSocket: live domain-event push + session commands.
  const wss = new WebSocketServer({ noServer: true });
  const clients = new Set<WebSocket>();

  const send = (socket: WebSocket, message: ServerMessage): void => {
    if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(message));
  };

  const broadcast = (message: ServerMessage): void => {
    for (const client of clients) send(client, message);
  };

  // One coarse watcher: global catalogs at boot, project dirs added as
  // projects register. Any change → resources_changed → clients re-fetch.
  const resourceWatcher = watchResources({ home: resourceHome() }, () =>
    broadcast({ type: "resources_changed" }),
  );
  const watchedProjects = new Set<string>();
  const watchProject = (projectPath: string): void => {
    if (watchedProjects.has(projectPath)) return;
    watchedProjects.add(projectPath);
    resourceWatcher.add(ensureDirs(projectWatchDirs(projectPath)));
  };
  for (const project of projects.list()) watchProject(project.path);

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
      await resourceWatcher.close();
      await sessions.stopAll();
      wss.close();
      await fastify.close();
    },
  };
}
