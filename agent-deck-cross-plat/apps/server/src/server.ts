import { randomUUID } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import nodePath from "node:path";
import type { ServerMessage, SessionMeta } from "@agent-deck/contracts";
import { extensionBridgeConflict } from "@agent-deck/domain";
import {
  appendSystemPromptPath,
  defaultRoots,
  ensureDirs,
  projectWatchDirs,
  readMcpServers,
  scanAgents,
  scanExtensions,
  scanSkills,
  watchResources,
  ProviderLoginManager,
  type ResourceRoots,
} from "@agent-deck/resources";
import { writeBridgeExtension } from "@agent-deck/pi-host";
import fastifyStatic from "@fastify/static";
import Fastify, { type FastifyInstance } from "fastify";
import {
  buildMemoryPreamble,
  createOnDeviceEmbedder,
  EmbedderUnavailableError,
  injectableIndex,
  searchMemories,
  semanticSearchMemories,
  type Embedder,
  type MemorySearchHit,
  type MemoryStore,
} from "@agent-deck/memory";
import { FileMcpOAuthStore } from "@agent-deck/mcp";
import { BridgeRegistry } from "./bridge.ts";
import {
  asThinkingLevel,
  envDefaults,
  type NamedAgentLaunch,
  type ServerContext,
} from "./context.ts";
import { registerDeckBridgeTools } from "./bridgeTools.ts";
import { LoopEngine } from "./loopEngine.ts";
import {
  McpManager,
  mcpServerConfigsFromEnv,
  scopeMcpBridgeSpecs,
  type McpServerConfig,
} from "./mcpTools.ts";
import { McpOAuthCoordinator } from "./mcpOAuth.ts";
import { registerMemoryTools } from "./memoryTools.ts";
import { defaultDataDir, ProjectIndex, SessionIndex, SettingsStore } from "./persistence.ts";
import { ReceiptBus } from "./receipts.ts";
import { makeServerRuntime, type ServerRuntime } from "./runtime.ts";
import { registerBridgeRoutes } from "./routes/bridge.ts";
import { registerGitRoutes } from "./routes/git.ts";
import { registerLoopRoutes } from "./routes/loops.ts";
import { registerMcpRoutes } from "./routes/mcp.ts";
import { registerMemoryRoutes } from "./routes/memory.ts";
import { registerProjectRoutes } from "./routes/projects.ts";
import { registerResourceRoutes } from "./routes/resources.ts";
import { registerSessionRoutes } from "./routes/sessions.ts";
import { registerSettingsRoutes } from "./routes/settings.ts";
import { SessionManager } from "./SessionManager.ts";
import { SupervisorLog } from "./supervisor.ts";
import { createTerminalGateway } from "./terminalGateway.ts";
import { setupWebSocket } from "./wsHandler.ts";

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

export interface AgentDeckServer {
  fastify: FastifyInstance;
  port: number;
  sessions: SessionManager;
  receipts: ReceiptBus;
  /** App-managed tool registry (memory/mcp/subagents register their tools here). */
  bridge: BridgeRegistry;
  /** Records child subagents' contact_supervisor requests (progress_update, …). */
  supervisor: SupervisorLog;
  /**
   * Effect composition seam (Slice 3): the ManagedRuntime serving every
   * `serverLayers` service (runtime.ts). Created per server, disposed in
   * close(). Later slices resolve their services through this.
   */
  runtime: ServerRuntime;
  close(): Promise<void>;
}

export interface StartServerOptions {
  port?: number;
  host?: string;
  dataDir?: string;
  /** Serve a built web app (apps/web/dist) at /. */
  staticDir?: string;
  /**
   * Inject a semantic-recall embedder (tests). In production, semantic recall is
   * opt-in via AGENT_DECK_SEMANTIC_MEMORY=1, which lazily loads the real
   * on-device embedder; absent both, recall stays lexical+fuzzy (the default).
   */
  memoryEmbedder?: Embedder;
}

export async function startServer(options: StartServerOptions = {}): Promise<AgentDeckServer> {
  // Effect runtime first: services composed in runtime.ts live for exactly the
  // server's lifetime (disposed last in close(), so scoped services from later
  // slices get their finalizers after the HTTP/WS surface is gone).
  const effectRuntime = makeServerRuntime();
  try {
    return await initServer(options, effectRuntime);
  } catch (error) {
    // Startup failed after the runtime existed (e.g. fastify.listen rejecting
    // with EADDRINUSE): run the runtime's finalizers so scoped services
    // (Slice 4+, e.g. pi subprocesses) never leak on the error path.
    try {
      await effectRuntime.dispose();
    } catch {
      // Intentionally swallowed — the original startup error is the one that
      // matters and must not be masked by a dispose failure.
    }
    throw error;
  }
}

/** The body of {@link startServer}; split out so the caller can guarantee
 * `effectRuntime.dispose()` on ANY startup failure without a 400-line try. */
async function initServer(
  options: StartServerOptions,
  effectRuntime: ServerRuntime,
): Promise<AgentDeckServer> {
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
  // Persistent home for session worktrees (native "Session Worktrees" dir) — under
  // the data dir, NOT tmp, so a live session's isolated checkout survives + is
  // never swept by an OS temp cleanup.
  const worktreesRoot = nodePath.join(options.dataDir ?? defaultDataDir(), "session-worktrees");
  // Persistent clones of git-imported skill repos, kept for re-sync (native
  // SkillRepositorySyncService keeps the clone; the copy lands in the catalog).
  const skillReposRoot = nodePath.join(options.dataDir ?? defaultDataDir(), "skill-repos");

  // Recall engine. Lexical+fuzzy is the always-on default; SEMANTIC recall is
  // opt-in — an injected embedder (tests) or AGENT_DECK_SEMANTIC_MEMORY=1 (which
  // lazily loads the real on-device embedder, kept out of the base install). The
  // embedder is loaded once and reused; if it fails to load, recall silently
  // stays lexical. Every search path (bridge tool, /memory/search, recall hook)
  // routes through recallMemories so semantic applies everywhere when enabled.
  const semanticMemoryEnabled =
    options.memoryEmbedder !== undefined || process.env.AGENT_DECK_SEMANTIC_MEMORY === "1";
  let embedderPromise: Promise<Embedder> | undefined;
  let embedderFailed = false;
  async function resolveEmbedder(): Promise<Embedder | undefined> {
    if (options.memoryEmbedder) return options.memoryEmbedder;
    if (process.env.AGENT_DECK_SEMANTIC_MEMORY !== "1" || embedderFailed) return undefined;
    if (!embedderPromise) embedderPromise = createOnDeviceEmbedder();
    try {
      return await embedderPromise;
    } catch (error) {
      embedderPromise = undefined;
      const message = error instanceof Error ? error.message : String(error);
      if (error instanceof EmbedderUnavailableError) {
        // A missing optional dep can't appear without a restart — stop retrying.
        embedderFailed = true;
        console.warn(`[memory] semantic recall unavailable, using lexical: ${message}`);
      } else {
        // A transient init failure (e.g. first-run model download) — allow retry.
        console.warn(
          `[memory] semantic embedder init failed (will retry), using lexical: ${message}`,
        );
      }
      return undefined;
    }
  }
  async function recallMemories(
    store: MemoryStore,
    query: string,
    limit?: number,
  ): Promise<MemorySearchHit[]> {
    if (!semanticMemoryEnabled) return searchMemories(store, query, limit);
    const embedder = await resolveEmbedder();
    // semanticSearchMemories itself falls back to lexical if an embed call throws.
    return embedder
      ? semanticSearchMemories(store, query, embedder, limit === undefined ? {} : { limit })
      : searchMemories(store, query, limit);
  }

  // `broadcast` lives in the WebSocket layer (wsHandler.ts) and
  // `cancelChildSupervisorRequests` in the bridge/supervisor route module —
  // both are wired up below, after the state they need exists. The closures
  // created here only capture the bindings and never run before assignment;
  // the throwing initializers keep any unexpected early call failing fast.
  let broadcast: (message: ServerMessage) => void = () => {
    throw new Error("broadcast called before the WebSocket layer was set up");
  };
  let cancelChildSupervisorRequests: (childSessionId: string) => void = () => {
    throw new Error("cancelChildSupervisorRequests called before the bridge routes registered");
  };

  const sessions = new SessionManager(
    effectRuntime,
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
    // Resolve a named agent for `managed_subagent{agent}` delegation, scoped to
    // the delegating session's project. Invoked only at subagent-run time, so the
    // forward reference to `resolveNamedAgent`/`rootsFor` (defined below) is
    // resolved by then. A disabled or missing agent isn't delegatable → undefined.
    (name, projectId) => {
      const resolved = resolveNamedAgent(name, projectId);
      if (resolved.status !== "ok") return undefined;
      const { agent } = resolved;
      return {
        body: agent.body,
        model: agent.model,
        thinking: asThinkingLevel(agent.thinking),
        tools: agent.tools,
        skillDirs: agent.skillDirs,
      };
    },
    // Live autoTitle preference (native OnboardingPreferencesView). `settings` is
    // declared below; this closure only runs at title time, long after startup.
    () => settings.get().autoTitle,
  );
  // Loop run engine (native single-agent loop). Each run's agent executor is
  // built per-run, bound to a parent session in the project cwd.
  const loopEngine = new LoopEngine();
  // Interactive provider OAuth login relay (native PiProviderLoginService).
  const providerLogin = new ProviderLoginManager();
  const projects = new ProjectIndex(options.dataDir);
  const settings = new SettingsStore(options.dataDir);

  // Resolve a named agent to the launch inputs a session (parent-backed OR a
  // delegated subagent) adopts, scoped to a project. One source of truth for
  // "launch a pi session from a named agent definition" — the agent-backed
  // /sessions route and the managed_subagent{agent} delegation share it, so a
  // subagent inherits the SAME persona/model/thinking/skills the parent launch
  // would. `not_found`/`disabled` are distinguished for the route's status codes.
  function resolveNamedAgent(
    name: string,
    projectId?: string,
  ): { status: "ok"; agent: NamedAgentLaunch } | { status: "not_found" } | { status: "disabled" } {
    const roots = rootsFor(projectId);
    const agent = scanAgents(roots).find((a) => a.name === name && !a.shadowed);
    if (!agent) return { status: "not_found" };
    if (agent.disabled) return { status: "disabled" };
    const skillsByName = new Map(scanSkills(roots).map((s) => [s.name, s]));
    const disabledSkills = new Set(settings.get().disabledSkills);
    const skillDirs = (agent.skills ?? [])
      .filter((skillName) => !disabledSkills.has(skillName)) // disabled skills never inject
      .map((skillName) => skillsByName.get(skillName)?.baseDir)
      .filter((p): p is string => Boolean(p));
    return {
      status: "ok",
      agent: {
        body: agent.body,
        systemPromptMode: agent.systemPromptMode,
        model: agent.model,
        thinking: agent.thinking,
        tools: agent.tools?.filter((tool) => !BRIDGE_ONLY_TOOLS.has(tool)),
        skillDirs,
        extensions: agent.extensions ?? [],
      },
    };
  }

  // Which app-bridge tool a user extension conflicts with (else null). Reading the
  // source is best-effort: an unreadable file simply isn't flagged. pi hard-fails
  // to launch when two extensions register the same tool, so a conflicting one is
  // excluded from the launch (below) rather than allowed to crash the session.
  function extensionBridgeConflictAt(filePath: string): string | null {
    try {
      return extensionBridgeConflict(readFileSync(filePath, "utf8"));
    } catch {
      return null;
    }
  }

  // The user extensions to inject at launch: the manually-added registry PLUS the
  // ones DISCOVERED in the standard pi dirs (global + this project's), minus any
  // disabled or bridge-conflicting, deduped by absolute path. (App-generated
  // bridge extensions are added separately by the launch, never here.) A disabled
  // flag is keyed by the absolute path, so it applies to discovered and added
  // alike. Excluding bridge-conflicting extensions is a SAFETY requirement: pi
  // crashes if a user extension re-registers a bridge tool name.
  function enabledExtensionPaths(projectId?: string): string[] {
    // "agentDeckManaged" (native PiAgentExtensionLoadingMode): load ONLY the app
    // bridges — the user's own pi extensions stay off (still listed in the UI).
    if (settings.get().extensionLoadingMode === "agentDeckManaged") return [];
    const disabled = new Set(settings.get().disabledExtensions);
    const registry = settings.get().extensions;
    const discovered = scanExtensions(rootsFor(projectId)).map((e) => e.path);
    return [...new Set([...registry, ...discovered])].filter(
      (p) => !disabled.has(p) && extensionBridgeConflictAt(p) === null,
    );
  }

  // Native memory tools (memory.md), registered on the bridge and scoped to each
  // session's project via its cwd. The launch-time index/policy injection is
  // handled by the parent-append factory above.
  if (memoryEnabled) {
    registerMemoryTools(
      bridge,
      memoryBaseDir,
      (sessionId) => sessions.get(sessionId)?.meta.cwd,
      recallMemories,
    );
  }

  // Native subagents + the session activity plan: the deck-agent bridge tools
  // every parent session gets (moved verbatim to bridgeTools.ts).
  registerDeckBridgeTools(bridge, sessions);

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
  // MCP OAuth (native MCPOAuthService): authed http servers get a per-server
  // OAuth provider whose tokens persist under the app data dir. The redirect
  // target is where the browser lands after authorization; the loopback capture
  // of that redirect is finalized in the UI slice (env-overridable meanwhile).
  const mcpOAuth = new McpOAuthCoordinator({
    store: new FileMcpOAuthStore(nodePath.join(options.dataDir ?? defaultDataDir(), "mcp-oauth")),
    redirectUrl:
      process.env.AGENT_DECK_MCP_OAUTH_REDIRECT ?? "http://127.0.0.1:33418/mcp/oauth/callback",
  });
  const mcp = new McpManager(bridge, {
    httpAuthProvider: (id) => mcpOAuth.providerFor(id),
  });
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

  // WebSocket layer (wsHandler.ts): socket accept, subscribe/replay,
  // client-message dispatch. Set up before the route modules register so
  // `broadcast` is live when they capture it.
  // Slice 8a: per-session terminal PTYs, scope-owned through the runtime.
  // Held here (not just inside the WS layer) so close() can run the awaited
  // closeAll() sweep — terminal scopes are detached roots dispose() can't reap.
  const terminals = createTerminalGateway(effectRuntime);
  const { close: closeWebSockets, broadcast: wsBroadcast } = setupWebSocket({
    fastify,
    sessions,
    terminals,
  });
  broadcast = wsBroadcast;

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

  // The shared context the route modules read (Slice 2 decomposition): one
  // object, assembled once, so every moved handler body reads exactly as it
  // did in the monolith.
  const ctx: ServerContext = {
    fastify,
    sessions,
    index,
    projects,
    settings,
    bridge,
    bridgeTokens,
    supervisor,
    childSupervisors,
    pendingSupervisor,
    loopEngine,
    providerLogin,
    mcp,
    mcpOAuth,
    memoryEnabled,
    memoryBaseDir,
    worktreesRoot,
    skillReposRoot,
    recallMemories,
    resolveNamedAgent,
    extensionBridgeConflictAt,
    enabledExtensionPaths,
    resourceHome,
    rootsFor,
    broadcast,
    watchProject,
  };

  // Route modules. Fastify's router matches on method + path (never on
  // registration order), so grouping the routes by module preserves behavior;
  // within each module the original registration order is unchanged.
  registerResourceRoutes(ctx);
  registerMemoryRoutes(ctx);
  registerMcpRoutes(ctx);
  registerSettingsRoutes(ctx);
  registerGitRoutes(ctx);
  registerLoopRoutes(ctx);
  registerProjectRoutes(ctx);
  registerSessionRoutes(ctx);
  ({ cancelChildSupervisorRequests } = registerBridgeRoutes(ctx));

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
    runtime: effectRuntime,
    close: async () => {
      // Teardown is fault-tolerant: one failing subsystem must not stop the
      // rest from closing, and the Effect runtime's finalizers (scoped
      // services, Slice 4+) must run even when an earlier step throws — hence
      // per-step error collection plus `finally` around dispose().
      const errors: unknown[] = [];
      const step = async (run: () => unknown): Promise<void> => {
        try {
          await run();
        } catch (error) {
          errors.push(error);
        }
      };
      try {
        await step(() => resourceWatcher.close());
        await step(() => sessions.stopAll());
        await step(() => mcp.close());
        await step(() => closeWebSockets());
        // Deterministic terminal teardown (the sessions.stopAll() analogue):
        // socket-close teardown is fire-and-forget and terminal scopes are
        // detached roots, so await the PTY kills BEFORE dispose() below.
        await step(() => terminals.closeAll());
        await step(() => fastify.close());
      } finally {
        // Dispose LAST, after the HTTP/WS surface is gone (see startServer).
        await effectRuntime.dispose();
      }
      if (errors.length === 1) throw errors[0];
      if (errors.length > 1) throw new AggregateError(errors, "agent-deck server close failed");
    },
  };
}
