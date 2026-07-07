import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { randomUUID } from "node:crypto";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import type { IncomingMessage } from "node:http";
import { homedir, tmpdir } from "node:os";
import nodePath from "node:path";
import {
  clientMessageSchema,
  type ProjectMeta,
  type ServerMessage,
  type SessionMeta,
  type SessionPlanItem,
  type SkillInfo,
} from "@agent-deck/domain";
import {
  appendSystemPromptPath,
  computeBuiltinOverride,
  defaultRoots,
  deleteMcpServer,
  ensureDirs,
  isValidHttpMcpUrl,
  McpConfigError,
  readMcpServers,
  writeMcpServer,
  mergeWithUnmanagedOverrideFields,
  parseAgentFile,
  projectWatchDirs,
  readAgentOverrides,
  scanAgents,
  scanSkills,
  scanPrompts,
  watchResources,
  writeAgentFile,
  writeBuiltinAgentOverride,
  writeSkillFile,
  writePromptFile,
  deleteAgentFile,
  setAgentDisabledFile,
  deleteSkillDir,
  deletePromptFile,
  renamePromptFile,
  renameAgentFile,
  renameSkillDir,
  importSkillFile,
  scanEnv,
  writeEnvVar,
  discoverProjects,
  detectProjectType,
  listProjectFiles,
  BUILTIN_AGENTS_DIR,
  type ResourceRoots,
} from "@agent-deck/resources";
import { runDoctor, writeBridgeExtension } from "@agent-deck/pi-host";
import fastifyStatic from "@fastify/static";
import Fastify, { type FastifyInstance } from "fastify";
import { WebSocketServer, type WebSocket } from "ws";
import { z } from "zod";
import {
  buildMemoryPreamble,
  buildRecalledMemories,
  deleteMemory,
  getMemory,
  injectableIndex,
  listMemories,
  searchMemories,
  setMemoryStatus,
  writeMemory,
  type MemoryStore,
  type MemoryType,
} from "@agent-deck/memory";
import { BridgeRegistry } from "./bridge.ts";
import {
  McpManager,
  mcpServerConfigsFromEnv,
  scopeMcpBridgeSpecs,
  type McpServerConfig,
} from "./mcpTools.ts";
import { registerMemoryTools } from "./memoryTools.ts";
import { defaultDataDir, ProjectIndex, SessionIndex, SettingsStore } from "./persistence.ts";
import { SupervisorLog, type SupervisorMethod } from "./supervisor.ts";
import { ReceiptBus } from "./receipts.ts";
import {
  SessionManager,
  type AgentSessionPlan,
  type LaunchPlan,
  type ManagedSession,
} from "./SessionManager.ts";

/** Resource names become file/dir names — never let them traverse paths. */
const RESOURCE_NAME = z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._-]*$/, "invalid resource name");

const createProjectBody = z.object({
  path: z.string(),
  name: z.string().optional(),
});

const patchProjectBody = z.object({
  assignedSkills: z.array(RESOURCE_NAME).optional(),
  defaultAgentName: RESOURCE_NAME.nullable().optional(),
  enabled: z.boolean().optional(),
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

/** A tool call arriving from a session's generated bridge extension. */
const bridgeCallBody = z.object({
  sessionId: z.string(),
  token: z.string(),
  tool: z.string(),
  toolCallId: z.string(),
  params: z.record(z.unknown()).default({}),
});

/** Tools only bridge extensions provide — stripped from an agent's --tools
 * allowlist until those bridges are ported. managed_subagent is now a real
 * bridge tool, so it's no longer stripped (an agent may allowlist it). */
const BRIDGE_ONLY_TOOLS = new Set(["contact_supervisor", "ask_user"]);

/**
 * The child subagent's supervisor tool. Exposed ONLY through the per-child bridge
 * (never in the parent bridge's specs, so a parent never sees it). Non-blocking
 * `progress_update` acknowledges immediately; the BLOCKING `need_decision` /
 * `interview_request` suspend the child until the supervisor answers, and the
 * answer becomes this tool's result.
 */
const CONTACT_SUPERVISOR_SPEC = {
  name: "contact_supervisor",
  label: "Contact supervisor",
  description:
    "Talk to your supervisor. 'progress_update' reports a short status and returns immediately (non-blocking). 'need_decision' and 'interview_request' ASK the supervisor a question and BLOCK until they answer — the answer is returned to you as the tool result. Use a blocking method only when you genuinely cannot proceed without a decision.",
  parameters: {
    type: "object",
    properties: {
      method: {
        type: "string",
        enum: ["progress_update", "need_decision", "interview_request"],
        description:
          "'progress_update' (non-blocking status), or 'need_decision' / 'interview_request' (block until answered).",
      },
      message: {
        type: "string",
        description:
          "The status (progress_update) or the question/decision to put to the supervisor.",
      },
      title: { type: "string", description: "Optional short title for the request." },
      options: {
        type: "array",
        items: { type: "string" },
        description: "Optional suggested choices for a need_decision.",
      },
    },
    required: ["method", "message"],
    additionalProperties: false,
  },
  promptSnippet:
    "contact_supervisor — progress_update (non-blocking), or need_decision/interview_request (block for an answer).",
} as const;

/** How long a blocking supervisor request waits for an answer before giving up. */
const SUPERVISOR_TIMEOUT_MS = 110_000;

const THINKING_LEVELS = new Set(["off", "minimal", "low", "medium", "high", "xhigh"]);

const agentEditFields = z.object({
  description: z.string().optional(),
  whenToUse: z.string().optional(),
  model: z.string().optional(),
  thinking: z.string().optional(),
  systemPromptMode: z.enum(["replace", "append"]).optional(),
  tools: z.array(z.string()).optional(),
  skills: z.array(z.string()).optional(),
  mcpServers: z.array(z.string()).optional(),
  body: z.string().optional(),
});

const agentEditBody = z.object({
  projectId: z.string().optional(),
  scope: z.enum(["builtin", "global", "project"]),
  name: RESOURCE_NAME,
  edit: agentEditFields,
});

const skillEditBody = z.object({
  projectId: z.string().optional(),
  scope: z.enum(["global", "project"]),
  name: RESOURCE_NAME,
  edit: z.object({
    description: z.string().optional(),
    body: z.string().optional(),
  }),
});

function asThinkingLevel(value: string | undefined): AgentSessionPlan["thinking"] {
  return value && THINKING_LEVELS.has(value) ? (value as AgentSessionPlan["thinking"]) : undefined;
}

/**
 * Finalize a session's --extension list: resolve, drop duplicates (loading the
 * same extension twice is wasteful/buggy), and skip anything that isn't a real
 * file right now (an added extension can be deleted or moved after the fact).
 */
function finalizeExtensions(paths: Array<string | undefined>): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const raw of paths) {
    if (!raw) continue;
    const resolved = nodePath.resolve(raw);
    if (seen.has(resolved)) continue;
    seen.add(resolved);
    if (existsSync(resolved) && statSync(resolved).isFile()) out.push(resolved);
  }
  return out;
}

/**
 * Session defaults from the server environment. The e2e harness (and any dev
 * setup) uses these to route UI-created sessions to the mock provider without
 * the UI knowing: AGENT_DECK_DEFAULT_PROVIDER, AGENT_DECK_DEFAULT_MODEL,
 * AGENT_DECK_DEFAULT_EXTENSIONS (path.delimiter-separated),
 * AGENT_DECK_PROVIDER_EXTENSIONS (provider-registration extensions only —
 * the ONLY extensions isolated helper launches may load),
 * AGENT_DECK_PI_ENV (JSON object merged into the pi subprocess env).
 */
function envDefaults(): {
  provider?: string;
  model?: string;
  extensions?: string[];
  providerExtensions?: string[];
  env?: Record<string, string>;
} {
  const extensions = process.env.AGENT_DECK_DEFAULT_EXTENSIONS?.split(nodePath.delimiter).filter(
    Boolean,
  );
  const providerExtensions = process.env.AGENT_DECK_PROVIDER_EXTENSIONS?.split(
    nodePath.delimiter,
  ).filter(Boolean);
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
    providerExtensions: providerExtensions?.length ? providerExtensions : undefined,
    env,
  };
}

export interface AgentDeckServer {
  fastify: FastifyInstance;
  port: number;
  sessions: SessionManager;
  receipts: ReceiptBus;
  /** App-managed tool registry (memory/mcp/subagents register their tools here). */
  bridge: BridgeRegistry;
  /** Records child subagents' contact_supervisor requests (progress_update, …). */
  supervisor: SupervisorLog;
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
  // App-managed tool bridge (memory/mcp/subagents register here). The endpoint
  // is only known after listen(), so the factory reads it lazily and returns no
  // extension until both a tool is registered and the address is bound.
  const bridge = new BridgeRegistry();
  // Filled in after listen() binds a port; the factory closure reads it lazily.
  const bridgeAddress: { endpoint?: string } = {};
  // Per-session secret baked into each generated bridge extension. The /bridge
  // route requires a call's token to match its session's, so a local caller
  // can't invoke another session's (project/session-scoped) tools.
  const bridgeTokens = new Map<string, string>();
  // Supervisor channel (native-subagent-bridge.md): a child subagent talks UP to
  // its parent via a contact_supervisor tool. `supervisor` records those requests;
  // `childSupervisors` maps a child's bridge session id → the parent transcript
  // cell its progress flows into. v1 handles non-blocking progress_update only.
  const supervisor = new SupervisorLog();
  const childSupervisors = new Map<string, { parentSessionId: string; cellId: string }>();
  // Blocking supervisor requests awaiting an answer: requestId → resolver. The
  // child's contact_supervisor call is suspended on the /bridge request until
  // answerSupervisor() (via POST /supervisor/:id/answer) settles it.
  const pendingSupervisor = new Map<
    string,
    {
      parentSessionId: string;
      childSessionId: string;
      settle: (result: { content: string; isError?: boolean }) => void;
    }
  >();
  // Native memory (memory.md), on by default like the native app; storage under
  // the app data dir. AGENT_DECK_MEMORY=0 disables it entirely.
  const memoryEnabled = process.env.AGENT_DECK_MEMORY !== "0";
  const memoryBaseDir = nodePath.join(options.dataDir ?? defaultDataDir(), "memory");
  const sessions = new SessionManager(
    receipts,
    (meta) => {
      // User activity (create / resume / prompt / title) floats the session up
      // the most-recent-first list. Process exit is NOT activity: an ended or
      // crashed session keeps its last-active time instead of jumping to the top
      // (resume clears endedAt, so it re-floats correctly).
      if (!meta.endedAt) meta.updatedAt = new Date().toISOString();
      index.upsert(meta);
      // `broadcast` is initialized during startServer, before any meta changes.
      broadcast({ type: "session_meta", session: meta });
    },
    () => envDefaults().providerExtensions,
    (meta) => {
      if (bridge.size === 0 || !bridgeAddress.endpoint) return undefined;
      const token = randomUUID();
      bridgeTokens.set(meta.id, token);
      // Per-session MCP scoping: an agent that DECLARES mcpServers sees only those
      // servers' MCP tools; a plain session (no agent) or an agent that declares
      // none sees all configured MCP tools. Non-MCP tools are always exposed.
      let tools = bridge.specs();
      const allow = mcpAllowlistForSession(meta);
      if (allow) tools = scopeMcpBridgeSpecs(tools, allow);
      return writeBridgeExtension({
        endpoint: bridgeAddress.endpoint,
        sessionId: meta.id,
        token,
        tools,
        // Per-turn memory recall via a before_agent_start hook (only meaningful
        // when memory is on; the launch index carries just titles).
        recall: memoryEnabled,
      });
    },
    (cwd, home) => {
      // Parent system-prompt appends. When memory is off we add nothing, so pi
      // auto-discovers APPEND_SYSTEM.md itself. When on, we inject the memory
      // block — which suppresses that discovery — so we re-add the resolved
      // APPEND_SYSTEM.md path FIRST, then the memory block. Both are passed as
      // FILE PATHS (pi reads a path entry as a file): a multi-line literal
      // --append value is truncated on Windows, where pi runs via a .cmd shim
      // through cmd.exe. `home` is the pi child's HOME so the global
      // APPEND_SYSTEM.md resolves where pi would find it.
      if (!memoryEnabled) return { appends: [] };
      const appends: string[] = [];
      const appendPath = appendSystemPromptPath({ home, projectPath: cwd });
      if (appendPath) appends.push(appendPath);
      const block = buildMemoryPreamble(
        injectableIndex({ baseDir: memoryBaseDir, projectPath: cwd }),
      );
      const cleanupDir = mkdtempSync(nodePath.join(tmpdir(), "agent-deck-mem-append-"));
      const blockFile = nodePath.join(cleanupDir, "memory.md");
      writeFileSync(blockFile, block, "utf8");
      appends.push(blockFile);
      return { appends, cleanupDir };
    },
    // Child subagent supervisor bridge: registers a child-scoped bridge token +
    // supervisor route, and generates an extension exposing ONLY contact_supervisor
    // (never in the parent bridge's specs, so parents never get it). dispose()
    // tears the whole thing down after the child exits.
    (childSessionId, route) => {
      if (!bridgeAddress.endpoint) return undefined;
      const token = randomUUID();
      // Generate the extension FIRST; only register the token + route if it
      // succeeds, so a writeBridgeExtension failure can't leak map entries with
      // no dispose() to clean them (dispose is only returned on success).
      const extension = writeBridgeExtension({
        endpoint: bridgeAddress.endpoint,
        sessionId: childSessionId,
        token,
        tools: [CONTACT_SUPERVISOR_SPEC],
      });
      bridgeTokens.set(childSessionId, token);
      childSupervisors.set(childSessionId, route);
      return {
        extension,
        dispose: () => {
          // Release any still-pending blocking supervisor requests so a dead
          // child's suspended tool call doesn't linger until the timeout.
          cancelChildSupervisorRequests(childSessionId);
          bridgeTokens.delete(childSessionId);
          childSupervisors.delete(childSessionId);
          try {
            rmSync(nodePath.dirname(extension), { recursive: true, force: true });
          } catch {
            // Best-effort: a leftover temp dir is harmless.
          }
        },
      };
    },
  );
  const projects = new ProjectIndex(options.dataDir);
  const settings = new SettingsStore(options.dataDir);

  // Native memory tools (memory.md), registered on the bridge and scoped to each
  // session's project via its cwd. The launch-time index/policy injection is
  // handled by the parent-append factory above.
  if (memoryEnabled) {
    registerMemoryTools(bridge, memoryBaseDir, (sessionId) => sessions.get(sessionId)?.meta.cwd);
  }

  // Native subagents (native-subagent-bridge.md): a parent session can launch a
  // focused child pi to complete one task and report back. v1 is text-returning
  // (managed_subagent); parallel / supervisor / plan tools + the deck UI follow.
  const subagentParams = z.object({ task: z.string().trim().min(1) });
  bridge.register(
    {
      name: "managed_subagent",
      label: "Subagent",
      description:
        "Delegate a self-contained task to a fresh subagent (no conversation history) and get its result back. Use for focused, independent work you can hand off with a complete task description.",
      parameters: {
        type: "object",
        properties: {
          task: {
            type: "string",
            description: "A complete, self-contained description of the task for the subagent.",
          },
        },
        required: ["task"],
        additionalProperties: false,
      },
      promptSnippet: "managed_subagent — delegate a self-contained task to a fresh subagent.",
    },
    async (params, ctx) => {
      const parsed = subagentParams.safeParse(params);
      if (!parsed.success) {
        return {
          content: `Invalid managed_subagent arguments: ${parsed.error.message}`,
          isError: true,
        };
      }
      try {
        const result = await sessions.runSubagent(ctx.sessionId, parsed.data.task);
        return { content: result || "(the subagent returned no output)" };
      } catch (error) {
        return { content: `Subagent failed: ${String(error)}`, isError: true };
      }
    },
  );

  // Fan out several subagents at once. Each runs as its own child pi; the count
  // is capped so a single call can't spawn an unbounded number of processes.
  const parallelParams = z.object({ tasks: z.array(z.string().trim().min(1)).min(1).max(8) });
  bridge.register(
    {
      name: "managed_parallel",
      label: "Parallel subagents",
      description:
        "Run several self-contained tasks in parallel, each in its own fresh subagent, and get all their results back together. Use when the tasks are independent.",
      parameters: {
        type: "object",
        properties: {
          tasks: {
            type: "array",
            items: { type: "string" },
            minItems: 1,
            maxItems: 8,
            description: "Independent, self-contained task descriptions (max 8).",
          },
        },
        required: ["tasks"],
        additionalProperties: false,
      },
      promptSnippet: "managed_parallel — run several independent tasks in parallel subagents.",
    },
    async (params, ctx) => {
      const parsed = parallelParams.safeParse(params);
      if (!parsed.success) {
        return {
          content: `Invalid managed_parallel arguments: ${parsed.error.message}`,
          isError: true,
        };
      }
      // allSettled: one failing subagent doesn't drop the others' results.
      const settled = await Promise.allSettled(
        parsed.data.tasks.map((task) => sessions.runSubagent(ctx.sessionId, task)),
      );
      const anyOk = settled.some((r) => r.status === "fulfilled");
      const rendered = settled
        .map((result, index) => {
          const label = `### Subagent ${index + 1}`;
          return result.status === "fulfilled"
            ? `${label}\n${result.value || "(no output)"}`
            : `${label} (failed)\n${String(result.reason)}`;
        })
        .join("\n\n");
      return { content: rendered, isError: !anyOk };
    },
  );

  // Session activity plan (native activity-sidebar "Plan"): a PARENT agent
  // maintains a per-session checklist. set_session_plan REPLACES the list;
  // update_session_plan patches items by id. The plan rides the session's push
  // bus as domain state (plan_set / plan_update), so clients mirror it.
  const planStatus = z.enum(["todo", "in_progress", "done", "blocked", "skipped"]);
  const setPlanParams = z.object({
    items: z
      .array(
        z.object({
          id: z.string().trim().min(1).optional(),
          title: z.string().trim().min(1),
          status: planStatus.optional(),
        }),
      )
      .max(50),
  });
  const updatePlanParams = z.object({
    updates: z
      .array(
        z.object({
          id: z.string().trim().min(1),
          title: z.string().trim().min(1).optional(),
          status: planStatus.optional(),
        }),
      )
      .min(1)
      .max(50),
  });
  const renderPlan = (items: SessionPlanItem[]): string =>
    items.length === 0
      ? "(empty plan)"
      : items.map((it) => `- [${it.status}] ${it.id}: ${it.title}`).join("\n");
  bridge.register(
    {
      name: "set_session_plan",
      label: "Set plan",
      description:
        "Set (replace) this session's activity plan — a short checklist of the steps you'll take. Each item has a title and an optional status (todo/in_progress/done/blocked/skipped, default todo). The result lists each item's assigned id; use those ids with update_session_plan.",
      parameters: {
        type: "object",
        properties: {
          items: {
            type: "array",
            maxItems: 50,
            items: {
              type: "object",
              properties: {
                id: { type: "string", description: "Optional stable id; assigned if omitted." },
                title: { type: "string" },
                status: {
                  type: "string",
                  enum: ["todo", "in_progress", "done", "blocked", "skipped"],
                },
              },
              required: ["title"],
              additionalProperties: false,
            },
          },
        },
        required: ["items"],
        additionalProperties: false,
      },
      promptSnippet: "set_session_plan — set/replace the session's activity plan checklist.",
    },
    (params, ctx) => {
      const parsed = setPlanParams.safeParse(params);
      if (!parsed.success) {
        return {
          content: `Invalid set_session_plan arguments: ${parsed.error.message}`,
          isError: true,
        };
      }
      const session = sessions.get(ctx.sessionId);
      if (!session) return { content: "No such session for the plan.", isError: true };
      // Ids MUST be unique: a duplicate id would make update_session_plan patch
      // every matching item and collides React keys in the panel. Coin a fresh
      // id for anything missing or duplicated.
      const seen = new Set<string>();
      const items: SessionPlanItem[] = parsed.data.items.map((it) => {
        let id = it.id ?? randomUUID();
        if (seen.has(id)) id = randomUUID();
        seen.add(id);
        return { id, title: it.title, status: it.status ?? "todo" };
      });
      session.setPlan(items);
      return { content: `Plan set (${items.length} item(s)):\n${renderPlan(items)}` };
    },
  );
  bridge.register(
    {
      name: "update_session_plan",
      label: "Update plan",
      description:
        "Update items in this session's activity plan by id (from set_session_plan). Each update carries an id and a new status and/or title. Unknown ids are ignored.",
      parameters: {
        type: "object",
        properties: {
          updates: {
            type: "array",
            minItems: 1,
            maxItems: 50,
            items: {
              type: "object",
              properties: {
                id: { type: "string" },
                title: { type: "string" },
                status: {
                  type: "string",
                  enum: ["todo", "in_progress", "done", "blocked", "skipped"],
                },
              },
              required: ["id"],
              additionalProperties: false,
            },
          },
        },
        required: ["updates"],
        additionalProperties: false,
      },
      promptSnippet: "update_session_plan — patch plan items by id (status/title).",
    },
    (params, ctx) => {
      const parsed = updatePlanParams.safeParse(params);
      if (!parsed.success) {
        return {
          content: `Invalid update_session_plan arguments: ${parsed.error.message}`,
          isError: true,
        };
      }
      const session = sessions.get(ctx.sessionId);
      if (!session) return { content: "No such session for the plan.", isError: true };
      session.updatePlan(parsed.data.updates);
      return { content: `Plan updated.\n${renderPlan(session.plan)}` };
    },
  );

  // Proxy configured MCP servers' tools onto the bridge (best-effort — a server
  // that fails to connect is skipped). Registered before listen so the tools are
  // available to the first session launch. AGENT_DECK_MCP_SERVERS is a JSON array
  // of stdio server configs { id, command, args?, env?, cwd? }.
  // Source MCP servers from the global mcp.json (~/.pi/agent/mcp.json), with
  // AGENT_DECK_MCP_SERVERS overriding/adding by id (used by tests and as an
  // escape hatch). Both stdio (command) and http (url, Streamable HTTP) entries
  // are supported. Skip the real-home read under AGENT_DECK_TEST so tests stay
  // hermetic (they configure servers via the env override, never the real mcp.json).
  const mcpFromConfig = (process.env.AGENT_DECK_TEST === "1" ? [] : readMcpServers(defaultRoots()))
    .map((entry): McpServerConfig | null => {
      if (entry.transport === "http" && entry.url) return { id: entry.id, url: entry.url };
      if (entry.command) {
        return { id: entry.id, command: entry.command, args: entry.args, env: entry.env };
      }
      return null;
    })
    .filter((c): c is McpServerConfig => c !== null);
  const mcpConfigs = [
    ...new Map(
      [...mcpFromConfig, ...mcpServerConfigsFromEnv(process.env.AGENT_DECK_MCP_SERVERS)].map(
        (config) => [config.id, config],
      ),
    ).values(),
  ];
  const mcp = new McpManager(bridge);
  await mcp.connectAll(mcpConfigs);

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

  // The MCP-server allowlist for a session (native explicit-assignment model):
  // a PLAIN session (no agent) is unrestricted — undefined → all configured
  // servers. An AGENT session is opt-in: it gets ONLY the servers it declares, so
  // an agent that declares none, or one that was deleted/renamed since (no longer
  // resolves), gets [] → no MCP tools (never silently widened to all). Function
  // declaration so the bridge-extension factory (defined earlier) can call it —
  // it only runs at launch time, after rootsFor is assigned.
  function mcpAllowlistForSession(meta: SessionMeta): string[] | undefined {
    if (!meta.agentName) return undefined;
    const agent = scanAgents(rootsFor(meta.projectId)).find(
      (a) => a.name === meta.agentName && !a.shadowed,
    );
    return agent?.mcpServers ?? [];
  }

  fastify.get("/resources/agents", async (request) => {
    const { projectId } = request.query as { projectId?: string };
    return { agents: scanAgents(rootsFor(projectId)) };
  });

  // Skills carry the app-level disabled flag from settings.
  const enrichSkills = (skills: SkillInfo[]): SkillInfo[] => {
    const disabled = new Set(settings.get().disabledSkills);
    return skills.map((s) => ({ ...s, disabled: disabled.has(s.name) }));
  };

  fastify.get("/resources/skills", async (request) => {
    const { projectId } = request.query as { projectId?: string };
    return { skills: enrichSkills(scanSkills(rootsFor(projectId))) };
  });

  // Delete a global/project skill (its SKILL.md dir) and forget it everywhere.
  fastify.delete("/resources/skills", async (request, reply) => {
    const parsed = z
      .object({
        projectId: z.string().optional(),
        scope: z.enum(["global", "project"]),
        name: RESOURCE_NAME,
      })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { projectId, scope, name } = parsed.data;
    if (scope === "project" && !rootsFor(projectId).projectPath) {
      return reply.status(400).send({ error: "projectId required for project scope" });
    }
    try {
      deleteSkillDir(rootsFor(projectId), scope, name);
      settings.forgetSkill(name);
      for (const project of projects.list()) {
        if (project.assignedSkills?.includes(name)) {
          projects.upsert({
            ...project,
            assignedSkills: project.assignedSkills.filter((s) => s !== name),
          });
        }
      }
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  // Rename a global/project skill directory (native RenameResourceSheet 7.x),
  // re-pointing every reference (app-level default/disabled lists + per-project
  // assignments) so the rename never silently drops an assignment.
  fastify.post("/resources/skills/rename", async (request, reply) => {
    const parsed = z
      .object({
        projectId: z.string().optional(),
        scope: z.enum(["global", "project"]),
        name: RESOURCE_NAME,
        newName: RESOURCE_NAME,
      })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { projectId, scope, name, newName } = parsed.data;
    const roots = rootsFor(projectId);
    if (scope === "project" && !roots.projectPath) {
      return reply.status(400).send({ error: "projectId required for project scope" });
    }
    try {
      renameSkillDir(roots, scope, name, newName);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (message === "skill_exists") {
        return reply
          .status(409)
          .send({ error: `A ${scope} skill named "${newName}" already exists.` });
      }
      if (message === "skill_not_found") {
        return reply.status(404).send({ error: `No ${scope} skill named "${name}".` });
      }
      return reply.status(500).send({ error: message });
    }
    // Re-point references. A project skill is visible only to its own project; a
    // global one, only where a same-named project skill doesn't shadow it.
    const hasProjectSkill = (projectPath: string): boolean =>
      existsSync(nodePath.join(projectPath, ".pi", "skills", name, "SKILL.md"));
    // The app-level default/disabled lists are FLAT, but a bare skill name
    // resolves per-project (a project skill shadows a global one). So re-point
    // them only when the old name no longer resolves to ANY skill anywhere —
    // then the swap can't misdirect a project that still has its own same-named
    // skill (nor leave a project-scoped default dangling).
    const globalSkillDir = nodePath.join(resourceHome(), ".pi", "agent", "skills");
    const nameStillResolves =
      existsSync(nodePath.join(globalSkillDir, name, "SKILL.md")) ||
      projects.list().some((p) => hasProjectSkill(p.path));
    if (!nameStillResolves) {
      settings.renameSkill(name, newName);
    }
    for (const project of projects.list()) {
      if (!project.assignedSkills?.includes(name)) continue;
      const applies =
        scope === "project" ? project.path === roots.projectPath : !hasProjectSkill(project.path);
      if (!applies) continue;
      projects.upsert({
        ...project,
        assignedSkills: [...new Set(project.assignedSkills.map((s) => (s === name ? newName : s)))],
      });
    }
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  // Import a local .md file as a skill (native SkillImportSheet Local tab).
  fastify.post("/resources/skills/import", async (request, reply) => {
    const parsed = z
      .object({
        projectId: z.string().optional(),
        scope: z.enum(["global", "project"]),
        sourcePath: z.string().min(1),
      })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { projectId, scope, sourcePath } = parsed.data;
    const roots = rootsFor(projectId);
    if (scope === "project" && !roots.projectPath) {
      return reply.status(400).send({ error: "projectId required for project scope" });
    }
    let name: string;
    try {
      name = importSkillFile(roots, scope, nodePath.resolve(sourcePath));
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (message === "skill_exists") {
        return reply.status(409).send({ error: `A ${scope} skill of that name already exists.` });
      }
      if (message === "not_a_markdown_file") {
        return reply.status(400).send({ error: "Pick an existing .md file to import." });
      }
      if (message === "invalid_skill_name") {
        return reply
          .status(400)
          .send({ error: "Couldn't derive a valid skill name from the file." });
      }
      return reply.status(500).send({ error: message });
    }
    broadcast({ type: "resources_changed" });
    return { ok: true, name };
  });

  // Prompt templates: single .md files pi exposes as /prompt:<name>.
  fastify.get("/resources/prompts", async (request) => {
    const { projectId } = request.query as { projectId?: string };
    return { prompts: scanPrompts(rootsFor(projectId)) };
  });

  const promptWriteBody = z.object({
    projectId: z.string().optional(),
    scope: z.enum(["global", "project"]),
    name: RESOURCE_NAME,
    edit: z.object({ description: z.string().max(500).optional(), body: z.string().max(100_000) }),
  });

  fastify.put("/resources/prompts", async (request, reply) => {
    const parsed = promptWriteBody.safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { projectId, scope, name, edit } = parsed.data;
    if (scope === "project" && !rootsFor(projectId).projectPath) {
      return reply.status(400).send({ error: "projectId required for project scope" });
    }
    try {
      writePromptFile(rootsFor(projectId), scope, name, edit);
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  fastify.delete("/resources/prompts", async (request, reply) => {
    const parsed = z
      .object({
        projectId: z.string().optional(),
        scope: z.enum(["global", "project"]),
        name: RESOURCE_NAME,
      })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { projectId, scope, name } = parsed.data;
    if (scope === "project" && !rootsFor(projectId).projectPath) {
      return reply.status(400).send({ error: "projectId required for project scope" });
    }
    try {
      deletePromptFile(rootsFor(projectId), scope, name);
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  // Rename a prompt template on disk (native RenameResourceSheet). Same scope;
  // 409 if the target name is taken, 404 if the source is gone.
  fastify.post("/resources/prompts/rename", async (request, reply) => {
    const parsed = z
      .object({
        projectId: z.string().optional(),
        scope: z.enum(["global", "project"]),
        name: RESOURCE_NAME,
        newName: RESOURCE_NAME,
      })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { projectId, scope, name, newName } = parsed.data;
    if (scope === "project" && !rootsFor(projectId).projectPath) {
      return reply.status(400).send({ error: "projectId required for project scope" });
    }
    try {
      renamePromptFile(rootsFor(projectId), scope, name, newName);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (message === "prompt_exists") {
        return reply
          .status(409)
          .send({ error: `A ${scope} prompt named "${newName}" already exists.` });
      }
      if (message === "prompt_not_found") {
        return reply.status(404).send({ error: `No ${scope} prompt named "${name}".` });
      }
      return reply.status(500).send({ error: message });
    }
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  // Extensions: user-added pi extension files (.ts/.js) merged into every
  // session's --extension list. Enable/disable without removing the entry.
  fastify.get("/resources/extensions", async () => {
    const disabled = new Set(settings.get().disabledExtensions);
    return {
      extensions: settings.get().extensions.map((filePath) => ({
        path: filePath,
        name: nodePath.basename(filePath),
        exists: existsSync(filePath),
        disabled: disabled.has(filePath),
      })),
    };
  });

  fastify.post("/resources/extensions", async (request, reply) => {
    const parsed = z.object({ path: z.string().min(1) }).safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const filePath = nodePath.resolve(parsed.data.path);
    if (!existsSync(filePath) || !statSync(filePath).isFile()) {
      return reply.status(400).send({ error: `not a file: ${filePath}` });
    }
    settings.addExtension(filePath);
    broadcast({ type: "resources_changed" });
    return { ok: true, path: filePath };
  });

  fastify.post("/resources/extensions/disabled", async (request, reply) => {
    const parsed = z
      .object({ path: z.string().min(1), disabled: z.boolean() })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    settings.setExtensionDisabled(parsed.data.path, parsed.data.disabled);
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  fastify.delete("/resources/extensions", async (request, reply) => {
    const parsed = z.object({ path: z.string().min(1) }).safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    settings.removeExtension(parsed.data.path);
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  // Memory inspection: browse and manage a project's stored memories (the
  // visible half of memory.md). Project-scoped by the project's path — the same
  // key its sessions write under — so one project never sees another's.
  const memoryStoreFor = (projectId?: string): MemoryStore | null => {
    if (!memoryEnabled || !projectId) return null;
    const project = projects.find((p) => p.id === projectId);
    return project ? { baseDir: memoryBaseDir, projectPath: project.path } : null;
  };

  const memoryPatchBody = z
    .object({
      projectId: z.string(),
      status: z.enum(["active", "pinned", "stale", "archived"]).optional(),
      edit: z
        .object({
          type: z.enum(["context", "decision", "runbook", "failure", "preference"]),
          title: z.string().min(1),
          summary: z.string().min(1),
          body: z.string().min(1),
          tags: z.array(z.string()).optional(),
        })
        .optional(),
    })
    // A PATCH must change something — status or edit — else it's a bad request.
    .refine((v) => v.status !== undefined || v.edit !== undefined, {
      message: "provide status or edit",
    });

  const memoryCreateBody = z.object({
    projectId: z.string(),
    type: z.enum(["context", "decision", "runbook", "failure", "preference"]),
    title: z.string().min(1),
    summary: z.string().min(1),
    body: z.string().min(1),
    tags: z.array(z.string()).optional(),
  });

  fastify.get("/memory", async (request, reply) => {
    const store = memoryStoreFor((request.query as { projectId?: string }).projectId);
    if (!store) return reply.code(400).send({ error: "memory requires a known project" });
    return { memories: listMemories(store) };
  });

  // Memory recall search (native Memory search 11.8): runs the SAME lexical+fuzzy
  // engine the agent recalls with (searchMemories) and returns the ranked hits —
  // active/pinned only, abstaining (empty) when nothing matches.
  fastify.get("/memory/search", async (request, reply) => {
    const { projectId, q } = request.query as { projectId?: string; q?: string };
    const store = memoryStoreFor(projectId);
    if (!store) return reply.code(400).send({ error: "memory requires a known project" });
    const query = (q ?? "").trim();
    if (!query) return { memories: [] };
    return { memories: searchMemories(store, query).map((hit) => hit.record) };
  });

  fastify.post("/memory", async (request, reply) => {
    const parsed = memoryCreateBody.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.message });
    const store = memoryStoreFor(parsed.data.projectId);
    if (!store) return reply.code(400).send({ error: "memory requires a known project" });
    // A manual UI create is deliberate — bypass the near-duplicate guard.
    const result = writeMemory(store, {
      ...parsed.data,
      type: parsed.data.type as MemoryType,
      confirmNew: true,
    });
    if (!result.ok) return reply.code(400).send({ error: result.message });
    broadcast({ type: "resources_changed" });
    return reply.code(201).send({ memory: result.record });
  });

  fastify.get("/memory/:id", async (request, reply) => {
    const store = memoryStoreFor((request.query as { projectId?: string }).projectId);
    if (!store) return reply.code(400).send({ error: "memory requires a known project" });
    const memory = getMemory(store, (request.params as { id: string }).id);
    if (!memory) return reply.code(404).send({ error: "unknown memory" });
    return { memory };
  });

  fastify.patch("/memory/:id", async (request, reply) => {
    const parsed = memoryPatchBody.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.message });
    const store = memoryStoreFor(parsed.data.projectId);
    if (!store) return reply.code(400).send({ error: "memory requires a known project" });
    const { id } = request.params as { id: string };
    // The schema guarantees status or edit is present.
    const result = parsed.data.edit
      ? writeMemory(store, { id, ...parsed.data.edit, type: parsed.data.edit.type as MemoryType })
      : setMemoryStatus(store, id, parsed.data.status!);
    if (!result.ok) {
      return reply.code(result.reason === "not_found" ? 404 : 400).send({ error: result.message });
    }
    broadcast({ type: "resources_changed" });
    return { memory: result.record };
  });

  fastify.delete("/memory/:id", async (request, reply) => {
    const store = memoryStoreFor((request.query as { projectId?: string }).projectId);
    if (!store) return reply.code(400).send({ error: "memory requires a known project" });
    if (!deleteMemory(store, (request.params as { id: string }).id)) {
      return reply.code(404).send({ error: "unknown memory" });
    }
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  // MCP servers: list live connection state, add/remove/refresh. Adds/removes
  // are written to the app-owned global mcp.json and reflected on the bridge.
  // Add either a stdio server (command [+ args/env]) or an http server (url).
  const mcpAddBody = z.union([
    z.object({
      name: z.string().min(1),
      command: z.string().min(1),
      args: z.array(z.string()).optional(),
      env: z.record(z.string()).optional(),
    }),
    z.object({
      name: z.string().min(1),
      url: z.string().refine(isValidHttpMcpUrl, "url must be a valid http(s) URL"),
    }),
  ]);

  fastify.get("/mcp", async () => {
    return { servers: mcp.status() };
  });

  fastify.post("/mcp", async (request, reply) => {
    const parsed = mcpAddBody.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.message });
    const data = parsed.data;
    const input =
      "url" in data ? { url: data.url } : { command: data.command, args: data.args, env: data.env };
    try {
      writeMcpServer(rootsFor(), "global", data.name, input);
    } catch (error) {
      const message = error instanceof McpConfigError ? error.message : String(error);
      return reply.code(400).send({ error: message });
    }
    const status = await mcp.connect({ id: data.name, ...input });
    broadcast({ type: "resources_changed" });
    return reply.code(201).send({ server: status });
  });

  fastify.delete("/mcp/:id", async (request, reply) => {
    const { id } = request.params as { id: string };
    const removed = await mcp.remove(id);
    // Also remove it from the config (it may be config-only if never connected,
    // or manager-only if env-sourced). Succeed when EITHER had it.
    let deletedConfig = false;
    try {
      deletedConfig = deleteMcpServer(rootsFor(), "global", id);
    } catch {
      // A malformed mcp.json is not the delete's problem — the live server is gone.
    }
    if (!removed && !deletedConfig) return reply.code(404).send({ error: "unknown MCP server" });
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  fastify.post("/mcp/:id/refresh", async (request, reply) => {
    const status = await mcp.refresh((request.params as { id: string }).id);
    if (!status) return reply.code(404).send({ error: "unknown MCP server" });
    broadcast({ type: "resources_changed" });
    return { server: status };
  });

  // Edit-safety contract: builtin agents are NEVER written — edits become a
  // diff vs the pristine builtin at settings.json → subagents.agentOverrides.
  // The UI sends the complete form state, so the computed diff fully replaces
  // any prior override (reverting a field back to base clears it).
  fastify.put("/resources/agents", async (request, reply) => {
    const parsed = agentEditBody.safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { projectId, scope, name, edit } = parsed.data;
    const roots = rootsFor(projectId);
    try {
      if (scope === "builtin") {
        const builtinFile = nodePath.join(BUILTIN_AGENTS_DIR, `${name}.md`);
        if (!existsSync(builtinFile)) {
          return reply.status(404).send({ error: `unknown builtin agent: ${name}` });
        }
        const base = parseAgentFile(builtinFile, readFileSync(builtinFile, "utf8"), "builtin");
        // Merge: fields this editor doesn't manage (disabled, native-only keys, …)
        // survive; managed fields are fully recomputed from the form state.
        const merged = mergeWithUnmanagedOverrideFields(
          readAgentOverrides(roots)[name],
          computeBuiltinOverride(base, edit),
        );
        writeBuiltinAgentOverride(roots, name, merged);
      } else {
        if (scope === "project" && !roots.projectPath) {
          return reply.status(400).send({ error: "projectId required for project scope" });
        }
        writeAgentFile(roots, scope, name, edit);
      }
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
    // settings.json isn't under the resource watcher — notify clients directly.
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  // Toggle an agent's disabled flag: override for builtins, frontmatter for
  // global/project. Library agents are read-only.
  fastify.post("/resources/agents/disabled", async (request, reply) => {
    const parsed = z
      .object({
        projectId: z.string().optional(),
        scope: z.enum(["builtin", "global", "project"]),
        name: RESOURCE_NAME,
        disabled: z.boolean(),
      })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { projectId, scope, name, disabled } = parsed.data;
    const roots = rootsFor(projectId);
    try {
      if (scope === "builtin") {
        if (!existsSync(nodePath.join(BUILTIN_AGENTS_DIR, `${name}.md`))) {
          return reply.status(404).send({ error: `unknown builtin agent: ${name}` });
        }
        const existing = readAgentOverrides(roots)[name] ?? {};
        const next = { ...existing };
        if (disabled) next.disabled = true;
        else delete next.disabled;
        writeBuiltinAgentOverride(roots, name, Object.keys(next).length > 0 ? next : null);
      } else {
        if (scope === "project" && !roots.projectPath) {
          return reply.status(400).send({ error: "projectId required for project scope" });
        }
        setAgentDisabledFile(roots, scope, name, disabled);
      }
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  // Delete a custom (global/project) agent's file. Builtins can't be deleted;
  // "delete" for a builtin means removing its override (reset to pristine).
  fastify.delete("/resources/agents", async (request, reply) => {
    const parsed = z
      .object({
        projectId: z.string().optional(),
        scope: z.enum(["builtin", "global", "project"]),
        name: RESOURCE_NAME,
      })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { projectId, scope, name } = parsed.data;
    const roots = rootsFor(projectId);
    try {
      if (scope === "builtin") {
        if (!existsSync(nodePath.join(BUILTIN_AGENTS_DIR, `${name}.md`))) {
          return reply.status(404).send({ error: `unknown builtin agent: ${name}` });
        }
        // "Reset to pristine" — remove the entire override, including any
        // unmanaged keys (mcpServers, …). This is why the UI only offers
        // reset for a builtin that is currently overridden.
        writeBuiltinAgentOverride(roots, name, null);
      } else {
        if (scope === "project" && !roots.projectPath) {
          return reply.status(400).send({ error: "projectId required for project scope" });
        }
        deleteAgentFile(roots, scope, name);
        // A deleted agent can no longer be a project default.
        for (const project of projects.list()) {
          if (project.defaultAgentName === name) {
            projects.upsert({ ...project, defaultAgentName: undefined });
          }
        }
      }
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  // Rename a global/project agent on disk (native RenameResourceSheet 6.5).
  // Builtins can't be renamed (their name is the override key). Any project
  // whose default pointed at the old name is re-pointed at the new one.
  fastify.post("/resources/agents/rename", async (request, reply) => {
    const parsed = z
      .object({
        projectId: z.string().optional(),
        scope: z.enum(["global", "project"]),
        name: RESOURCE_NAME,
        newName: RESOURCE_NAME,
      })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { projectId, scope, name, newName } = parsed.data;
    const roots = rootsFor(projectId);
    if (scope === "project" && !roots.projectPath) {
      return reply.status(400).send({ error: "projectId required for project scope" });
    }
    try {
      renameAgentFile(roots, scope, name, newName);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (message === "agent_exists") {
        return reply
          .status(409)
          .send({ error: `A ${scope} agent named "${newName}" already exists.` });
      }
      if (message === "agent_not_found") {
        return reply.status(404).send({ error: `No ${scope} agent named "${name}".` });
      }
      return reply.status(500).send({ error: message });
    }
    // Re-point project defaults, but ONLY where this rename actually changes the
    // effective default — bare-name resolution respects scope shadowing (a
    // project-scoped agent shadows a same-named global one). Over-broad matching
    // would silently redirect a default onto a different, live agent.
    const hasProjectAgent = (projectPath: string): boolean =>
      existsSync(nodePath.join(projectPath, ".pi", "agents", `${name}.md`)) ||
      existsSync(nodePath.join(projectPath, ".agents", `${name}.md`));
    for (const project of projects.list()) {
      if (project.defaultAgentName !== name) continue;
      if (scope === "project") {
        // A project agent is visible only to its own project.
        if (project.path === roots.projectPath) {
          projects.upsert({ ...project, defaultAgentName: newName });
        }
      } else if (!hasProjectAgent(project.path)) {
        // Global rename: skip projects whose own project-scoped agent of that
        // name shadows the global (their default resolves to the project one).
        projects.upsert({ ...project, defaultAgentName: newName });
      }
    }
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  fastify.put("/resources/skills", async (request, reply) => {
    const parsed = skillEditBody.safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { projectId, scope, name, edit } = parsed.data;
    const roots = rootsFor(projectId);
    if (scope === "project" && !roots.projectPath) {
      return reply.status(400).send({ error: "projectId required for project scope" });
    }
    try {
      writeSkillFile(roots, scope, name, edit);
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  // Runtime screens: masked env inspector and the doctor health probe.
  fastify.get("/runtime/env", async (request) => {
    const { projectId } = request.query as { projectId?: string };
    return { entries: scanEnv(rootsFor(projectId)) };
  });

  // Set or add an env var (value provided) in the given scope's .env.
  fastify.put("/runtime/env", async (request, reply) => {
    const parsed = z
      .object({
        projectId: z.string().optional(),
        scope: z.enum(["global", "project"]),
        key: z.string().regex(/^[A-Za-z_][A-Za-z0-9_]*$/, "invalid env key"),
        value: z
          .string()
          .max(100_000)
          .refine((v) => !/[\r\n]/.test(v), "env values cannot contain newlines"),
      })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { projectId, scope, key, value } = parsed.data;
    if (scope === "project" && !rootsFor(projectId).projectPath) {
      return reply.status(400).send({ error: "projectId required for project scope" });
    }
    try {
      writeEnvVar(rootsFor(projectId), scope, key, value);
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  // Delete an env var from the given scope's .env.
  fastify.delete("/runtime/env", async (request, reply) => {
    const parsed = z
      .object({
        projectId: z.string().optional(),
        scope: z.enum(["global", "project"]),
        key: z.string().regex(/^[A-Za-z_][A-Za-z0-9_]*$/, "invalid env key"),
      })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { projectId, scope, key } = parsed.data;
    if (scope === "project" && !rootsFor(projectId).projectPath) {
      return reply.status(400).send({ error: "projectId required for project scope" });
    }
    try {
      writeEnvVar(rootsFor(projectId), scope, key, null);
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  fastify.get("/runtime/doctor", async () => ({ report: await runDoctor(resourceHome()) }));

  fastify.get("/settings", async () => ({ settings: settings.get() }));

  fastify.patch("/settings", async (request, reply) => {
    const parsed = z
      .object({
        defaultSkills: z.array(RESOURCE_NAME).optional(),
        /** Atomic membership ops — preferred over whole-array replacement. */
        setDefaultSkill: z.object({ name: RESOURCE_NAME, enabled: z.boolean() }).optional(),
        setDisabledSkill: z.object({ name: RESOURCE_NAME, disabled: z.boolean() }).optional(),
      })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    if (parsed.data.setDefaultSkill) {
      const { name, enabled } = parsed.data.setDefaultSkill;
      return { settings: settings.setDefaultSkill(name, enabled) };
    }
    if (parsed.data.setDisabledSkill) {
      const { name, disabled } = parsed.data.setDisabledSkill;
      const result = settings.setDisabledSkill(name, disabled);
      broadcast({ type: "resources_changed" }); // dims the row, updates assignment
      return { settings: result };
    }
    return { settings: settings.update(parsed.data) };
  });

  fastify.get("/projects", async () => ({
    projects: projects.list().filter((p) => !p.hidden),
  }));

  // Root folders that are too broad to scan (filesystem/system roots) — a
  // huge fan-out would block the sync scan. Users add specific dev folders.
  const FORBIDDEN_ROOTS = new Set(
    [
      "/",
      "/etc",
      "/usr",
      "/bin",
      "/sbin",
      "/var",
      "/sys",
      "/proc",
      "/dev",
      "/System",
      "/Library",
      "/private",
      homedir(), // the bare home dir fans out enormously; a subfolder is fine
    ].map((p) => nodePath.resolve(p)),
  );

  const canonicalPath = (p: string): string => {
    try {
      return realpathSync.native(p);
    } catch {
      return nodePath.resolve(p);
    }
  };

  // Discovery roots + scan. GET returns the configured roots and every
  // project candidate found under them (flagged if already registered).
  fastify.get("/projects/discovery", async () => {
    const roots = settings.get().projectRoots;
    const known = new Set(projects.list().map((p) => canonicalPath(p.path)));
    const discovered = discoverProjects(roots).map((c) => ({
      ...c,
      registered: known.has(canonicalPath(c.path)),
    }));
    return { roots, discovered };
  });

  fastify.post("/projects/discovery/roots", async (request, reply) => {
    const parsed = z.object({ root: z.string().min(1) }).safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const root = nodePath.resolve(parsed.data.root);
    if (!existsSync(root) || !statSync(root).isDirectory()) {
      return reply.status(400).send({ error: `not a directory: ${root}` });
    }
    if (FORBIDDEN_ROOTS.has(root) || nodePath.dirname(root) === root) {
      return reply.status(400).send({ error: "root is too broad to scan; pick a project folder" });
    }
    return { roots: settings.setProjectRoot(root, true).projectRoots };
  });

  fastify.delete("/projects/discovery/roots", async (request, reply) => {
    const parsed = z.object({ root: z.string().min(1) }).safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    return {
      roots: settings.setProjectRoot(nodePath.resolve(parsed.data.root), false).projectRoots,
    };
  });

  fastify.post("/projects", async (request, reply) => {
    const parsed = createProjectBody.safeParse(request.body);
    if (!parsed.success) {
      return reply.status(400).send({ error: parsed.error.message });
    }
    const projectPath = nodePath.resolve(parsed.data.path);
    if (!existsSync(projectPath) || !statSync(projectPath).isDirectory()) {
      return reply.status(400).send({ error: `not a directory: ${projectPath}` });
    }
    // Idempotent by path: re-adding an existing (possibly hidden) project
    // returns it with its metadata intact — hide is never data loss.
    const existing = projects.find((p) => p.path === projectPath);
    if (existing) {
      if (existing.hidden) {
        const restored = { ...existing, hidden: false };
        projects.upsert(restored);
        return reply.status(200).send({ project: restored });
      }
      return reply.status(200).send({ project: existing });
    }
    const project: ProjectMeta = {
      id: randomUUID(),
      path: projectPath,
      name: parsed.data.name ?? nodePath.basename(projectPath),
      type: detectProjectType(projectPath),
      createdAt: new Date().toISOString(),
    };
    projects.upsert(project);
    watchProject(project.path);
    return reply.status(201).send({ project });
  });

  fastify.patch("/projects/:id", async (request, reply) => {
    const parsed = patchProjectBody.safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { id } = request.params as { id: string };
    const project = projects.find((p) => p.id === id);
    if (!project) return reply.status(404).send({ error: "unknown project" });
    const next: ProjectMeta = { ...project };
    if (parsed.data.assignedSkills !== undefined) next.assignedSkills = parsed.data.assignedSkills;
    if (parsed.data.defaultAgentName !== undefined) {
      next.defaultAgentName = parsed.data.defaultAgentName ?? undefined;
    }
    if (parsed.data.enabled !== undefined) next.enabled = parsed.data.enabled;
    projects.upsert(next);
    return { project: next };
  });

  // Live pi session state (model, thinking level, streaming flags) and the
  // available-model catalog — the composer's picker data.
  fastify.get("/sessions/:id/state", async (request, reply) => {
    const { id } = request.params as { id: string };
    const session = sessions.get(id);
    if (!session) return reply.status(404).send({ error: "unknown session" });
    try {
      return { state: await session.getState() };
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
  });

  fastify.get("/sessions/:id/models", async (request, reply) => {
    const { id } = request.params as { id: string };
    const session = sessions.get(id);
    if (!session) return reply.status(404).send({ error: "unknown session" });
    try {
      const models = await session.getAvailableModels();
      // Mark models the user hid from the picker (app-level, native "Disabled").
      const disabled = new Set(settings.get().disabledModels);
      return {
        models: models.map((m) => ({
          ...m,
          disabled: disabled.has(`${m.provider}:${m.id}`),
        })),
      };
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
  });

  // Hide/show a model in the picker (app-level curation, the native Enabled/Disabled toggle).
  fastify.post("/runtime/models/disabled", async (request, reply) => {
    const parsed = z
      .object({ provider: z.string().min(1), id: z.string().min(1), disabled: z.boolean() })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    settings.setModelDisabled(`${parsed.data.provider}:${parsed.data.id}`, parsed.data.disabled);
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  // Session slash commands (skills/prompts pi actually loaded) — also how
  // tests verify that assigned --skill flags landed inside pi.
  fastify.get("/sessions/:id/commands", async (request, reply) => {
    const { id } = request.params as { id: string };
    const session = sessions.get(id);
    if (!session) return reply.status(404).send({ error: "unknown session" });
    try {
      return { commands: await session.getCommands() };
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
  });

  // Project-relative file list for `@`-file autocomplete, scoped to the
  // session's cwd. Bounded + symlink-safe (see listProjectFiles).
  fastify.get("/sessions/:id/files", async (request, reply) => {
    const { id } = request.params as { id: string };
    const { q } = request.query as { q?: string };
    const session = sessions.get(id);
    if (!session) return reply.status(404).send({ error: "unknown session" });
    return { files: listProjectFiles(session.meta.cwd, q ?? "").slice(0, 50) };
  });

  // "Hide from list" (native): soft-hide — metadata and session links are
  // preserved and re-adding the same path restores them. The project hosting
  // a LIVE session can't be hidden.
  fastify.delete("/projects/:id", async (request, reply) => {
    const { id } = request.params as { id: string };
    const project = projects.find((p) => p.id === id);
    if (!project) return reply.status(404).send({ error: "unknown project" });
    const hasLiveSession = sessions.list().some((s) => s.projectId === id && !s.endedAt);
    if (hasLiveSession) {
      return reply.status(409).send({ error: "project has a live session" });
    }
    projects.upsert({ ...project, hidden: true });
    return { ok: true };
  });

  // Project instructions: pi auto-loads a context file every turn. It reads the
  // FIRST of AGENTS.md / AGENTS.MD / CLAUDE.md / CLAUDE.MD it finds (AGENTS wins),
  // so we edit that effective file — a CLAUDE.md project shows CLAUDE.md, not an
  // empty AGENTS.md editor. A fresh location defaults to AGENTS.md.
  const instructionsBody = z.object({ content: z.string().max(200_000) });
  const INSTRUCTION_FILENAMES = ["AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"];
  const resolveInstructionsFile = (dir: string): string => {
    for (const name of INSTRUCTION_FILENAMES) {
      const candidate = nodePath.join(dir, name);
      if (existsSync(candidate)) return candidate;
    }
    return nodePath.join(dir, "AGENTS.md");
  };
  const agentsFileFor = (id: string): { path: string } | null => {
    const project = projects.find((p) => p.id === id);
    return project ? { path: resolveInstructionsFile(project.path) } : null;
  };

  const INSTRUCTIONS_MAX = 1_000_000;

  fastify.get("/projects/:id/instructions", async (request, reply) => {
    const target = agentsFileFor((request.params as { id: string }).id);
    if (!target) return reply.status(404).send({ error: "unknown project" });
    let content = "";
    if (existsSync(target.path)) {
      if (statSync(target.path).size > INSTRUCTIONS_MAX) {
        return reply.status(413).send({ error: "the instructions file is too large to edit here" });
      }
      content = readFileSync(target.path, "utf8");
    }
    return { content, path: target.path };
  });

  fastify.put("/projects/:id/instructions", async (request, reply) => {
    const target = agentsFileFor((request.params as { id: string }).id);
    if (!target) return reply.status(404).send({ error: "unknown project" });
    const parsed = instructionsBody.safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    // Never write THROUGH a symlink — a symlinked AGENTS.md could redirect the
    // write to a file outside the project.
    if (existsSync(target.path) && lstatSync(target.path).isSymbolicLink()) {
      return reply
        .status(400)
        .send({ error: "the instructions file is a symlink; refusing to write" });
    }
    writeFileSync(target.path, parsed.data.content, "utf8");
    return { ok: true, path: target.path };
  });

  // Global instructions: ~/.pi/agent/AGENTS.md, which pi loads as global context
  // for every session (agent-deck-system-prompt-logic.md §context files).
  // Editable with no project selected — the project-scoped file is separate.
  const globalAgentsPath = (): string =>
    resolveInstructionsFile(nodePath.join(resourceHome(), ".pi", "agent"));

  fastify.get("/runtime/instructions", async (_request, reply) => {
    const filePath = globalAgentsPath();
    let content = "";
    if (existsSync(filePath)) {
      if (statSync(filePath).size > INSTRUCTIONS_MAX) {
        return reply.status(413).send({ error: "the instructions file is too large to edit here" });
      }
      content = readFileSync(filePath, "utf8");
    }
    return { content, path: filePath };
  });

  fastify.put("/runtime/instructions", async (request, reply) => {
    const parsed = instructionsBody.safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const filePath = globalAgentsPath();
    // Never write THROUGH a symlink (same guard as the project file).
    if (existsSync(filePath) && lstatSync(filePath).isSymbolicLink()) {
      return reply
        .status(400)
        .send({ error: "the instructions file is a symlink; refusing to write" });
    }
    mkdirSync(nodePath.dirname(filePath), { recursive: true });
    writeFileSync(filePath, parsed.data.content, "utf8");
    return { ok: true, path: filePath };
  });

  // GitHub issues for a project, via the gh CLI (reuses the user's gh auth so
  // there's no OAuth to build). AGENT_DECK_GH_BIN overrides the binary (tests).
  const execFileAsync = promisify(execFile);
  fastify.get("/projects/:id/issues", async (request, reply) => {
    const project = projects.find((p) => p.id === (request.params as { id: string }).id);
    if (!project) return reply.status(404).send({ error: "unknown project" });
    // Filter by issue state (native Issues screen's Open / Closed / All segmented control).
    const stateParsed = z
      .enum(["open", "closed", "all"])
      .default("open")
      .safeParse((request.query as { state?: string }).state);
    if (!stateParsed.success) return reply.status(400).send({ error: "invalid state filter" });
    const ghBin = process.env.AGENT_DECK_GH_BIN || "gh";
    try {
      const { stdout } = await execFileAsync(
        ghBin,
        [
          "issue",
          "list",
          "--state",
          stateParsed.data,
          "--json",
          // assignees is included so the Issues screen can offer the native
          // client-side assignee filter (native filteredBoardItems) over the
          // already-loaded board without a per-filter re-query.
          "number,title,state,url,labels,assignees",
          "--limit",
          "50",
        ],
        { cwd: project.path, timeout: 15_000, maxBuffer: 8_000_000 },
      );
      const raw = JSON.parse(stdout) as Array<{
        number: number;
        title: string;
        state: string;
        url: string;
        labels?: Array<{ name: string }>;
        assignees?: Array<{ login: string }>;
      }>;
      return {
        issues: raw.map((i) => ({
          number: i.number,
          title: i.title,
          state: i.state,
          url: i.url,
          labels: (i.labels ?? []).map((l) => l.name),
          assignees: (i.assignees ?? []).map((a) => a.login),
        })),
      };
    } catch {
      return {
        issues: [],
        error:
          "Couldn't list issues — needs the gh CLI installed, authenticated, and a GitHub remote.",
      };
    }
  });

  // A single issue's detail (native GitHubIssueDetailView 10.6): title + state +
  // labels + assignees + author + Markdown body, for the detail pane.
  fastify.get("/projects/:id/issues/:number", async (request, reply) => {
    const { id, number } = request.params as { id: string; number: string };
    const project = projects.find((p) => p.id === id);
    if (!project) return reply.status(404).send({ error: "unknown project" });
    if (!/^\d+$/.test(number)) return reply.status(400).send({ error: "invalid issue number" });
    const ghBin = process.env.AGENT_DECK_GH_BIN || "gh";
    try {
      const { stdout } = await execFileAsync(
        ghBin,
        [
          "issue",
          "view",
          number,
          "--json",
          "number,title,body,state,url,labels,assignees,author,comments",
        ],
        { cwd: project.path, timeout: 15_000, maxBuffer: 8_000_000 },
      );
      const raw = JSON.parse(stdout) as {
        number: number;
        title: string;
        body?: string;
        state: string;
        url: string;
        labels?: Array<{ name: string }>;
        assignees?: Array<{ login: string }>;
        author?: { login: string };
        comments?: Array<{ author?: { login: string }; body?: string; createdAt?: string }>;
      };
      return {
        issue: {
          number: raw.number,
          title: raw.title,
          body: raw.body ?? "",
          state: raw.state,
          url: raw.url,
          labels: (raw.labels ?? []).map((l) => l.name),
          assignees: (raw.assignees ?? []).map((a) => a.login),
          author: raw.author?.login ?? null,
          comments: (raw.comments ?? []).map((c) => ({
            author: c.author?.login ?? null,
            body: c.body ?? "",
            createdAt: c.createdAt ?? null,
          })),
        },
      };
    } catch {
      return reply.status(502).send({
        error: "Couldn't load the issue — needs the gh CLI installed, authenticated, and a remote.",
      });
    }
  });

  // Close an issue (native Issues close split-button 10.9): completed or not
  // planned. `gh issue close <n> --reason <reason>`.
  fastify.post("/projects/:id/issues/:number/close", async (request, reply) => {
    const { id, number } = request.params as { id: string; number: string };
    const project = projects.find((p) => p.id === id);
    if (!project) return reply.status(404).send({ error: "unknown project" });
    if (!/^\d+$/.test(number)) return reply.status(400).send({ error: "invalid issue number" });
    const parsed = z
      .object({ reason: z.enum(["completed", "not_planned"]) })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: "invalid close reason" });
    // gh spells the reason with a space; our API uses a snake_case enum.
    const ghReason = parsed.data.reason === "completed" ? "completed" : "not planned";
    const ghBin = process.env.AGENT_DECK_GH_BIN || "gh";
    try {
      await execFileAsync(ghBin, ["issue", "close", number, "--reason", ghReason], {
        cwd: project.path,
        timeout: 15_000,
        maxBuffer: 8_000_000,
      });
    } catch {
      return reply.status(502).send({
        error:
          "Couldn't close the issue — needs the gh CLI installed, authenticated, and a remote.",
      });
    }
    return { ok: true };
  });

  fastify.get("/sessions", async (request) => {
    const { projectId } = request.query as { projectId?: string };
    // Live sessions win over persisted index entries (same id).
    const live = sessions.list();
    const liveIds = new Set(live.map((s) => s.id));
    const all = [...index.list().filter((s) => !liveIds.has(s.id)), ...live].sort((a, b) =>
      a.createdAt.localeCompare(b.createdAt),
    );
    return { sessions: projectId ? all.filter((s) => s.projectId === projectId) : all };
  });

  // Reopen a session: live ones are returned as-is; ended ones are relaunched
  // against their pi session file with the transcript rebuilt from pi's
  // canonical history (never from our own logs).
  fastify.post("/sessions/:id/resume", async (request, reply) => {
    const { id } = request.params as { id: string };
    const live = sessions.get(id);
    if (live?.isRunning) return { session: live.meta };
    const meta = live?.meta ?? index.find((s) => s.id === id);
    if (!meta) return reply.status(404).send({ error: "unknown session" });
    if (!meta.piSessionFile) {
      return reply.status(409).send({ error: "session has no pi session file to resume" });
    }
    const defaults = envDefaults();
    try {
      const session = await sessions.resume(
        meta,
        {
          kind: "parent",
          resumeSessionPath: meta.piSessionFile,
          provider: defaults.provider,
          model: defaults.model,
          extensions: defaults.extensions,
        },
        defaults.env,
      );
      return { session: session.meta };
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
  });

  // Rename: updates pi's session name (when live) and the persisted title.
  fastify.patch("/sessions/:id", async (request, reply) => {
    const parsed = z.object({ title: z.string().trim().min(1).max(200) }).safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { id } = request.params as { id: string };
    const live = sessions.get(id);
    if (live) {
      await live.rename(parsed.data.title);
      return { session: live.meta };
    }
    const meta = index.find((s) => s.id === id);
    if (!meta) return reply.status(404).send({ error: "unknown session" });
    const next = { ...meta, title: parsed.data.title, updatedAt: new Date().toISOString() };
    index.upsert(next);
    broadcast({ type: "session_meta", session: next });
    return { session: next };
  });

  // Delete: stop the live process, drop the index entry, remove the pi
  // session file. Session content is destroyed — this is the explicit delete.
  fastify.delete("/sessions/:id", async (request, reply) => {
    const { id } = request.params as { id: string };
    const meta = sessions.get(id)?.meta ?? index.find((s) => s.id === id);
    if (!meta) return reply.status(404).send({ error: "unknown session" });
    await sessions.destroy(id);
    index.remove(id);
    bridgeTokens.delete(id);
    if (meta.piSessionFile) {
      try {
        rmSync(meta.piSessionFile, { force: true });
      } catch {
        // pi may still hold the file briefly; best-effort.
      }
    }
    broadcast({ type: "session_removed", sessionId: id });
    return { ok: true };
  });

  // Fork/duplicate: copy the source's pi session file and launch an
  // independent resumed session from the copy. The original is untouched.
  fastify.post("/sessions/:id/fork", async (request, reply) => {
    const { id } = request.params as { id: string };
    const live = sessions.get(id);
    const meta = live?.meta ?? index.find((s) => s.id === id);
    if (!meta) return reply.status(404).send({ error: "unknown session" });
    if (!meta.piSessionFile || !existsSync(meta.piSessionFile)) {
      return reply.status(409).send({ error: "session has no history to fork yet" });
    }
    // Copying a session file mid-write (streaming) can yield a torn copy the
    // fork can't resume — refuse while the source is actively responding.
    if (live?.isRunning) {
      try {
        const state = await live.getState();
        if (state.isStreaming) {
          return reply.status(409).send({ error: "cannot fork while the session is responding" });
        }
      } catch {
        // Couldn't read state — proceed; the source file is only appended to.
      }
    }
    const ext = nodePath.extname(meta.piSessionFile);
    const base = nodePath.basename(meta.piSessionFile, ext);
    const dir = nodePath.dirname(meta.piSessionFile);
    // Full UUID + existence check so the fork can never overwrite another file.
    let copyTo = "";
    do {
      copyTo = nodePath.join(dir, `${base}-fork-${randomUUID()}${ext}`);
    } while (existsSync(copyTo));
    try {
      const session = await sessions.fork(meta, meta.piSessionFile, copyTo, envDefaults().env);
      index.upsert(session.meta);
      return reply.status(201).send({ session: session.meta });
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
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
    // Base extensions (request or env defaults) + the user's enabled ones,
    // deduped and re-validated as real files at launch time.
    const baseExtensions = body.extensions ?? defaults.extensions ?? [];
    const finalizedBase = finalizeExtensions([...baseExtensions, ...settings.enabledExtensions()]);
    const extensions = finalizedBase.length > 0 ? finalizedBase : undefined;

    // Default + project skill assignments become explicit --skill paths on
    // parent sessions (pi-rpc-launch-flags.md §1: "Default + current Project
    // skill assignments"). Applied at session creation; a running session
    // keeps its flags until relaunched.
    // CONTRACT GAP: bridge/audit/web extensions and APPEND_SYSTEM.md
    // preservation are still missing here (M2).
    let assignedSkillPaths: string[] | undefined;
    {
      const project = body.projectId ? projects.find((p) => p.id === body.projectId) : undefined;
      const disabledSkills = new Set(settings.get().disabledSkills);
      const names = [...settings.get().defaultSkills, ...(project?.assignedSkills ?? [])].filter(
        (name) => !disabledSkills.has(name), // disabled skills are never injected
      );
      if (names.length > 0) {
        // scanSkills lists global catalogs first and the project catalog
        // last; the Map keeps the LAST entry per name, so a project skill
        // deliberately wins a name collision with a global one.
        const skillsByName = new Map(scanSkills(rootsFor(body.projectId)).map((s) => [s.name, s]));
        const missing = [...new Set(names)].filter((name) => !skillsByName.has(name));
        if (missing.length > 0) {
          fastify.log.warn({ missing }, "assigned skills not found in catalog");
        }
        const paths = [...new Set(names)]
          .map((name) => skillsByName.get(name)?.baseDir)
          .filter((p): p is string => Boolean(p));
        if (paths.length > 0) assignedSkillPaths = paths;
      }
    }

    let plan: LaunchPlan = {
      kind: "parent",
      provider,
      model,
      extensions,
      skills: body.skills ?? assignedSkillPaths,
    };

    if (body.agentName) {
      // Agent-backed session: the picked agent's body becomes the system
      // prompt; frontmatter tools/skills/model apply per the launch contract.
      const roots = rootsFor(body.projectId);
      const agent = scanAgents(roots).find((a) => a.name === body.agentName && !a.shadowed);
      if (!agent) return reply.status(404).send({ error: `unknown agent: ${body.agentName}` });
      if (agent.disabled) {
        return reply.status(409).send({ error: `agent is disabled: ${body.agentName}` });
      }
      const skillsByName = new Map(scanSkills(roots).map((s) => [s.name, s]));
      const disabledSkills = new Set(settings.get().disabledSkills);
      const agentSkillPaths = (agent.skills ?? [])
        .filter((name) => !disabledSkills.has(name)) // disabled skills never inject
        .map((name) => skillsByName.get(name)?.baseDir)
        .filter((p): p is string => Boolean(p));
      const effectiveTools = agent.tools?.filter((tool) => !BRIDGE_ONLY_TOOLS.has(tool));
      plan = {
        kind: "agent",
        systemPrompt: { mode: agent.systemPromptMode, text: agent.body },
        tools: effectiveTools,
        extensions: finalizeExtensions([...(extensions ?? []), ...(agent.extensions ?? [])]),
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

  // Handle a child subagent's contact_supervisor call. progress_update records +
  // streams into the parent's Subagent card and returns immediately;
  // need_decision / interview_request open a BLOCKING question card in the parent
  // and suspend the child until answerSupervisor() settles it — the answer becomes
  // the child's tool result. A pending wait is released either by an answer, a
  // timeout, or the child's bridge being disposed (child death). Returns the
  // bridge-shaped result the child receives.
  async function handleContactSupervisor(
    childSessionId: string,
    params: Record<string, unknown>,
  ): Promise<{ content: string; isError?: boolean }> {
    const route = childSupervisors.get(childSessionId);
    if (!route) {
      return { content: "No supervisor channel is available for this subagent.", isError: true };
    }
    const rawMethod = typeof params.method === "string" ? params.method : "";
    const validMethods: SupervisorMethod[] = [
      "progress_update",
      "need_decision",
      "interview_request",
    ];
    if (!validMethods.includes(rawMethod as SupervisorMethod)) {
      return {
        content: `contact_supervisor: unknown method '${rawMethod || "(missing)"}'.`,
        isError: true,
      };
    }
    const method = rawMethod as SupervisorMethod;
    const message = typeof params.message === "string" ? params.message.trim() : "";
    if (!message) {
      return { content: "contact_supervisor: 'message' is required.", isError: true };
    }
    const title =
      typeof params.title === "string" && params.title.trim() ? params.title.trim() : undefined;
    const parent = sessions.get(route.parentSessionId);

    if (method === "progress_update") {
      supervisor.record({
        parentSessionId: route.parentSessionId,
        cellId: route.cellId,
        method,
        title,
        message,
      });
      parent?.appendSubagentProgress(route.cellId, title ? `${title}: ${message}` : message);
      return { content: "Progress recorded." };
    }

    // Blocking: open a supervisor-question card and suspend until answered.
    const requestId = randomUUID();
    const options =
      Array.isArray(params.options) && params.options.every((o) => typeof o === "string")
        ? (params.options as string[])
        : undefined;
    supervisor.record({
      id: requestId,
      parentSessionId: route.parentSessionId,
      cellId: route.cellId,
      method,
      title,
      message,
    });
    parent?.openSupervisorQuestion({
      requestId,
      subagentCellId: route.cellId,
      method,
      title: title ?? (method === "need_decision" ? "Decision needed" : "Question"),
      message,
      options,
    });
    return await new Promise<{ content: string; isError?: boolean }>((resolve) => {
      let settled = false;
      const settle = (result: { content: string; isError?: boolean }): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        pendingSupervisor.delete(requestId);
        resolve(result);
      };
      const timer = setTimeout(() => {
        markSupervisorCancelled(requestId, route.parentSessionId, "Timed out with no answer.");
        settle({ content: "Supervisor request timed out with no answer.", isError: true });
      }, SUPERVISOR_TIMEOUT_MS);
      timer.unref();
      pendingSupervisor.set(requestId, {
        parentSessionId: route.parentSessionId,
        childSessionId,
        settle,
      });
    });
  }

  /** Mark a supervisor request cancelled in the log AND close its parent card,
   * so a resolved-without-answer request never leaves stale interactive UI. */
  function markSupervisorCancelled(
    requestId: string,
    parentSessionId: string,
    reason: string,
  ): void {
    supervisor.markCancelled(requestId, reason);
    sessions.get(parentSessionId)?.closeSupervisorQuestion(requestId, reason);
  }

  /**
   * Release every blocking supervisor request still pending for a child whose
   * bridge is being disposed (the child ended/timed out): mark each cancelled +
   * close its card, then settle its (now-dead) tool call so it doesn't linger to
   * the timeout.
   */
  function cancelChildSupervisorRequests(childSessionId: string): void {
    for (const [id, entry] of pendingSupervisor) {
      if (entry.childSessionId === childSessionId) {
        markSupervisorCancelled(id, entry.parentSessionId, "The subagent ended.");
        entry.settle({
          content: "Supervisor request cancelled (the subagent ended).",
          isError: true,
        });
        pendingSupervisor.delete(id);
      }
    }
  }

  /**
   * Deliver an answer to a pending blocking supervisor request: resolve the
   * child's suspended tool call with `response`, mark the record answered, and
   * flip the parent card to answered. Returns false if no such pending request.
   */
  function answerSupervisor(requestId: string, response: string): boolean {
    const pending = pendingSupervisor.get(requestId);
    if (!pending) return false;
    supervisor.markAnswered(requestId, response);
    sessions.get(pending.parentSessionId)?.answerSupervisorQuestion(requestId, response);
    pending.settle({ content: response });
    return true;
  }

  // Memory recall for the before_agent_start hook: rank the session project's
  // memories by lexical relevance to the user's message and return the top ones'
  // full bodies as an injectable block (empty → the hook injects nothing). The
  // launch index carries only titles; this surfaces the relevant bodies per turn.
  const RECALL_LIMIT = 4;
  function handleRecall(sessionId: string, params: Record<string, unknown>): { content: string } {
    if (!memoryEnabled) return { content: "" };
    const query = typeof params.query === "string" ? params.query : "";
    const cwd = sessions.get(sessionId)?.meta.cwd;
    if (!cwd || !query.trim()) return { content: "" };
    const store: MemoryStore = { baseDir: memoryBaseDir, projectPath: cwd };
    const hits = searchMemories(store, query, RECALL_LIMIT);
    return { content: buildRecalledMemories(hits.map((h) => h.record)) };
  }

  // The app side of the bridge: a session's generated extension POSTs each
  // app-managed tool call here, and the registry dispatches it to the handler.
  // Loopback-only (the pi subprocess is local); the response maps to the pi
  // tool result, including the error flag.
  fastify.post("/bridge", async (request, reply) => {
    const parsed = bridgeCallBody.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.message });
    }
    const expected = bridgeTokens.get(parsed.data.sessionId);
    if (!expected || expected !== parsed.data.token) {
      return reply.code(403).send({ error: "invalid bridge token" });
    }
    // A child subagent's contact_supervisor call routes to the supervisor channel
    // (recorded + streamed into the parent's card), NOT the parent bridge registry.
    // A blocking method suspends here until answered (or the child's bridge is
    // disposed on child death, which releases the wait).
    if (parsed.data.tool === "contact_supervisor") {
      return await handleContactSupervisor(parsed.data.sessionId, parsed.data.params);
    }
    // The before_agent_start recall hook asks for the memories most relevant to
    // the user's message (not a model-callable tool — an internal hook channel).
    if (parsed.data.tool === "__recall__") {
      return handleRecall(parsed.data.sessionId, parsed.data.params);
    }
    return await bridge.dispatch(parsed.data);
  });

  // Answer a pending blocking supervisor request (need_decision / interview_request)
  // raised by a child subagent. The "human out-of-band" path: the parent's
  // managed_subagent tool call is itself blocked awaiting the child, so this
  // answer arrives via the UI/REST while the child waits. Resolves the child's
  // suspended tool call with the response.
  const supervisorAnswerBody = z.object({ response: z.string() });
  fastify.post<{ Params: { requestId: string } }>(
    "/supervisor/:requestId/answer",
    async (request, reply) => {
      const parsed = supervisorAnswerBody.safeParse(request.body);
      if (!parsed.success) return reply.code(400).send({ error: parsed.error.message });
      const ok = answerSupervisor(request.params.requestId, parsed.data.response);
      if (!ok) return reply.code(404).send({ error: "no pending supervisor request with that id" });
      return { ok: true };
    },
  );

  await fastify.listen({ port: options.port ?? 0, host: options.host ?? "127.0.0.1" });
  const address = fastify.server.address();
  const port = typeof address === "object" && address !== null ? address.port : 0;
  // Now that the port is bound, bridge extensions can target this server. The
  // pi subprocess is always local, so loopback is correct regardless of host.
  bridgeAddress.endpoint = `http://127.0.0.1:${port}/bridge`;

  return {
    fastify,
    port,
    sessions,
    receipts,
    bridge,
    supervisor,
    close: async () => {
      await resourceWatcher.close();
      await sessions.stopAll();
      await mcp.close();
      wss.close();
      await fastify.close();
    },
  };
}
