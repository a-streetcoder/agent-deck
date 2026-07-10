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
import { readFile } from "node:fs/promises";
import type { IncomingMessage } from "node:http";
import { homedir, tmpdir } from "node:os";
import nodePath from "node:path";
import {
  clientMessageSchema,
  extensionBridgeConflict,
  type ProjectMeta,
  type ServerMessage,
  type SessionMeta,
  type SessionPlanItem,
  type SkillInfo,
  type PromptInfo,
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
  scanExtensions,
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
  importSkillsFromClone,
  resolveSkillSource,
  scanEnv,
  writeEnvVar,
  discoverProjects,
  detectProjectType,
  listProjectFiles,
  listProviders,
  isKnownProvider,
  logoutProvider,
  ProviderLoginManager,
  scanLoops,
  writeLoopFile,
  deleteLoopFile,
  duplicateLoop,
  BUILTIN_AGENTS_DIR,
  type ResourceRoots,
} from "@agent-deck/resources";
import { runDoctor, writeBridgeExtension } from "@agent-deck/pi-host";
import {
  gitClonePersistent,
  gitCommitAll,
  gitCommitsAhead,
  gitHead,
  gitLsRemote,
  gitPullFfInto,
  gitCurrentBranch,
  gitErrorText,
  gitMerge,
  gitPush,
  gitStatus,
  gitStatusAndDiff,
  gitWorktreeAdd,
  gitWorktreeRemove,
  isGitRepo,
  type GitWorktree,
} from "./git.ts";
import { LoopEngine } from "./loopEngine.ts";
import fastifyStatic from "@fastify/static";
import Fastify, { type FastifyInstance } from "fastify";
import { WebSocketServer, type WebSocket } from "ws";
import { z } from "zod";
import {
  buildMemoryPreamble,
  buildRecalledMemories,
  createOnDeviceEmbedder,
  EmbedderUnavailableError,
  deleteMemory,
  getMemory,
  injectableIndex,
  listMemories,
  searchMemories,
  semanticSearchMemories,
  setMemoryStatus,
  writeMemory,
  type Embedder,
  type MemorySearchHit,
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
import { FileMcpOAuthStore } from "@agent-deck/mcp";
import { McpOAuthCoordinator } from "./mcpOAuth.ts";
import { registerMemoryTools } from "./memoryTools.ts";
import {
  defaultDataDir,
  ProjectIndex,
  SessionIndex,
  SettingsStore,
  type AppSettings,
} from "./persistence.ts";
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
  assignedPrompts: z.array(RESOURCE_NAME).optional(),
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

// Commit-message generator prompt (native PiAgentShipService.commitMessageSystemPrompt).
const COMMIT_MESSAGE_SYSTEM_PROMPT = `You are Agent Deck's git commit message generator. Your only job is to write a commit message from the supplied git status and diff.

The commit message must be concise and explanatory: capture the concrete code or product change being committed, not the mechanical act of editing files. Prefer the intended behavior or user-visible outcome when the diff makes it clear.

Output ONLY the commit message — an imperative title (max 72 chars), optionally followed by a blank line and a short body. No preamble, no code fences, no quotes. Do not invent changes not supported by the status or diff.`;

const agentEditFields = z.object({
  description: z.string().optional(),
  whenToUse: z.string().optional(),
  model: z.string().optional(),
  fallbackModels: z.array(z.string()).optional(),
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
 * A fallback catalog skill name for a repo's root SKILL.md that lacks a
 * frontmatter name: the last URL/path segment, sanitized to the name charset and
 * guaranteed to start alnum so a valid root skill is never silently skipped.
 */
function skillRepoName(cloneUrl: string): string {
  return (
    (
      cloneUrl
        .replace(/\.git$/, "")
        .replace(/[/\\]+$/, "")
        .split(/[/\\]/)
        .pop() || "repository"
    )
      .replace(/[^A-Za-z0-9._-]/g, "-")
      .replace(/^[^A-Za-z0-9]+/, "") || "repository"
  );
}

/** The dir to scan for skills — the clone, or a subdir GUARANTEED to stay inside
 *  it (a crafted/legacy `../…` subdir falls back to the clone root). */
function subdirScanPath(clonePath: string, subdir?: string): string {
  if (!subdir) return clonePath;
  const base = nodePath.resolve(clonePath);
  const resolved = nodePath.resolve(clonePath, subdir);
  return resolved === base || resolved.startsWith(base + nodePath.sep) ? resolved : clonePath;
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
  /**
   * Inject a semantic-recall embedder (tests). In production, semantic recall is
   * opt-in via AGENT_DECK_SEMANTIC_MEMORY=1, which lazily loads the real
   * on-device embedder; absent both, recall stays lexical+fuzzy (the default).
   */
  memoryEmbedder?: Embedder;
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
  interface NamedAgentLaunch {
    body: string;
    systemPromptMode: "replace" | "append";
    model?: string;
    thinking?: string;
    /** Real pi tools the agent declares (bridge-only tools filtered out). */
    tools?: string[];
    /** Resolved skill base dirs, disabled skills removed. */
    skillDirs: string[];
    extensions: string[];
  }
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

  // Native subagents (native-subagent-bridge.md): a parent session can launch a
  // focused child pi to complete one task and report back. v1 is text-returning
  // (managed_subagent); parallel / supervisor / plan tools + the deck UI follow.
  const subagentParams = z.object({
    task: z.string().trim().min(1),
    agent: z.string().trim().min(1).optional(),
  });
  bridge.register(
    {
      name: "managed_subagent",
      label: "Subagent",
      description:
        "Delegate a self-contained task to a fresh subagent (no conversation history) and get its result back. Use for focused, independent work you can hand off with a complete task description. Optionally pass `agent` to delegate to one of your installed named agents (it adopts that agent's persona).",
      parameters: {
        type: "object",
        properties: {
          task: {
            type: "string",
            description: "A complete, self-contained description of the task for the subagent.",
          },
          agent: {
            type: "string",
            description:
              "Optional: the name of an installed agent to delegate to; the subagent adopts its persona. Omit for a plain anonymous subagent.",
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
        const result = await sessions.runSubagent(
          ctx.sessionId,
          parsed.data.task,
          parsed.data.agent,
        );
        return { content: result || "(the subagent returned no output)" };
      } catch (error) {
        return { content: `Subagent failed: ${String(error)}`, isError: true };
      }
    },
  );

  // Fan out several subagents at once. Each runs as its own child pi; the count
  // is capped so a single call can't spawn an unbounded number of processes.
  const parallelParams = z.object({
    tasks: z
      .array(
        // `.strict()` matches the item schema's additionalProperties:false, so an
        // unexpected field is rejected rather than silently stripped.
        z
          .object({
            task: z.string().trim().min(1),
            agent: z.string().trim().min(1).optional(),
          })
          .strict(),
      )
      .min(1)
      .max(8),
  });
  bridge.register(
    {
      name: "managed_parallel",
      label: "Parallel subagents",
      description:
        "Run several self-contained tasks in parallel, each in its own fresh subagent, and get all their results back together. Use when the tasks are independent. Each task may optionally name an `agent` to delegate to (it adopts that agent's persona).",
      parameters: {
        type: "object",
        properties: {
          tasks: {
            type: "array",
            items: {
              type: "object",
              properties: {
                task: {
                  type: "string",
                  description: "A complete, self-contained task description.",
                },
                agent: {
                  type: "string",
                  description:
                    "Optional: the name of an installed agent to delegate this task to; the subagent adopts its persona.",
                },
              },
              required: ["task"],
              additionalProperties: false,
            },
            minItems: 1,
            maxItems: 8,
            description: "Independent, self-contained tasks to run in parallel (max 8).",
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
        parsed.data.tasks.map((t) => sessions.runSubagent(ctx.sessionId, t.task, t.agent)),
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

  // Import skills from a git repository (native SkillRepositorySync, import half):
  // shallow-clone to a temp dir, copy each SKILL.md-bearing directory into the
  // scope's catalog, then discard the clone. Push/update-sync is a follow-up.
  fastify.post("/resources/skills/import-git", async (request, reply) => {
    const parsed = z
      .object({
        projectId: z.string().optional(),
        scope: z.enum(["global", "project"]),
        url: z.string().trim().min(1).max(2000),
      })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { projectId, scope, url } = parsed.data;
    const roots = rootsFor(projectId);
    if (scope === "project" && !roots.projectPath) {
      return reply.status(400).send({ error: "projectId required for project scope" });
    }
    // Accept the ways a user names a repo (native resolveSource): owner/repo, a
    // skills.sh link, an SSH remote, or a web tree URL (whose branch + path pin
    // the ref + subdir). A plain https URL still resolves to itself.
    const source = resolveSkillSource(url);
    if (!source) {
      return reply.status(400).send({ error: "Couldn't understand that repository reference." });
    }
    const repoName = skillRepoName(source.cloneUrl);
    // Clone into a PERSISTENT dir kept for re-sync (native keeps the clone; the
    // copy lands in the catalog). The clone is removed only on failure below or
    // when the repo is later forgotten.
    const repoId = randomUUID();
    const clonePath = nodePath.join(skillReposRoot, repoId);
    const cleanupClone = (): void => {
      try {
        rmSync(clonePath, { recursive: true, force: true, maxRetries: 5 });
      } catch {
        // Best-effort — a leftover clone dir is harmless.
      }
    };
    mkdirSync(skillReposRoot, { recursive: true });
    try {
      await gitClonePersistent(source.cloneUrl, clonePath, source.ref);
      // A subdir (from a deep link) scopes discovery to that subtree.
      const scanDir = subdirScanPath(clonePath, source.subdir);
      const result = importSkillsFromClone(roots, scope, scanDir, repoName);
      if (result.imported.length === 0 && result.skipped.length === 0) {
        cleanupClone();
        return reply.status(400).send({ error: "No SKILL.md found in that repository." });
      }
      // Record provenance so the repo can be checked for + pulled updates later.
      settings.upsertImportedSkillRepository({
        id: repoId,
        remoteUrl: source.cloneUrl,
        ref: source.ref,
        subdir: source.subdir,
        scope,
        projectPath: roots.projectPath,
        clonePath,
        skillNames: result.imported,
        lastSyncedCommit: await gitHead(clonePath).catch(() => ""),
        importedAt: new Date().toISOString(),
      });
      broadcast({ type: "resources_changed" });
      return { ...result, repoId };
    } catch (error) {
      cleanupClone();
      const message = error instanceof Error ? error.message : String(error);
      if (message === "clone_failed") {
        return reply.status(400).send({
          error:
            "Couldn't clone that repository — check the URL (private repos aren't supported yet).",
        });
      }
      return reply.status(500).send({ error: message });
    }
  });

  // Imported skill repositories (native importedSkillRepositories) — the git repos
  // a user synced skills from, so the UI can offer re-sync + forget.
  fastify.get("/resources/skill-repos", async () => {
    return {
      repos: settings.get().importedSkillRepositories.map((r) => ({
        id: r.id,
        remoteUrl: r.remoteUrl,
        ref: r.ref,
        scope: r.scope,
        skillNames: r.skillNames,
        lastSyncedCommit: r.lastSyncedCommit,
        importedAt: r.importedAt,
      })),
    };
  });

  // Check a repo for updates (native checkForUpdate) — a network-only ls-remote,
  // compared against the last synced commit.
  fastify.post("/resources/skill-repos/:id/check", async (request, reply) => {
    const { id } = request.params as { id: string };
    const record = settings.get().importedSkillRepositories.find((r) => r.id === id);
    if (!record) return reply.status(404).send({ error: "unknown skill repository" });
    const remoteCommit = await gitLsRemote(record.remoteUrl, record.ref);
    return {
      updateAvailable: remoteCommit !== null && remoteCommit !== record.lastSyncedCommit,
      // Distinguish "checked, up to date" from "couldn't reach the remote" so the
      // UI doesn't present a transient network failure as "all good".
      checkFailed: remoteCommit === null,
      remoteCommit,
      syncedCommit: record.lastSyncedCommit,
    };
  });

  // Update a repo (native update): fetch + ff the persistent clone, re-copy its
  // skills into the catalog (overwriting), and advance the synced commit.
  fastify.post("/resources/skill-repos/:id/update", async (request, reply) => {
    const { id } = request.params as { id: string };
    const record = settings.get().importedSkillRepositories.find((r) => r.id === id);
    if (!record) return reply.status(404).send({ error: "unknown skill repository" });
    if (!existsSync(record.clonePath)) {
      return reply.status(400).send({ error: "The clone is missing — re-import the repository." });
    }
    // Resolve the catalog roots for the record's scope (a project it was imported
    // into must still be registered).
    let roots: ResourceRoots;
    if (record.scope === "project") {
      const project = record.projectPath
        ? projects.find((p) => p.path === record.projectPath)
        : undefined;
      if (!project) {
        return reply.status(400).send({ error: "That project is no longer registered." });
      }
      roots = rootsFor(project.id);
    } else {
      roots = rootsFor(undefined);
    }
    try {
      const newCommit = await gitPullFfInto(record.clonePath, record.ref);
      if (newCommit === record.lastSyncedCommit) {
        return { updated: false, commit: newCommit }; // already up to date
      }
      const scanDir = subdirScanPath(record.clonePath, record.subdir);
      const result = importSkillsFromClone(
        roots,
        record.scope,
        scanDir,
        skillRepoName(record.remoteUrl),
        true, // overwrite — re-sync replaces the catalog copies
      );
      // Skills upstream DELETED (in the record before, now neither imported nor
      // skipped) are removed from the catalog too, so the repo stays the source
      // of truth (native) rather than leaving orphans.
      for (const name of record.skillNames) {
        if (!result.imported.includes(name) && !result.skipped.includes(name)) {
          try {
            deleteSkillDir(roots, record.scope, name);
          } catch {
            // Best-effort — a skill the user already removed is fine.
          }
        }
      }
      settings.upsertImportedSkillRepository({
        ...record,
        skillNames: result.imported,
        lastSyncedCommit: newCommit,
      });
      broadcast({ type: "resources_changed" });
      return { updated: true, commit: newCommit, imported: result.imported };
    } catch (error) {
      return reply
        .status(500)
        .send({ error: error instanceof Error ? error.message : String(error) });
    }
  });

  // Forget a repo: drop the provenance record + the persistent clone. The skills
  // already copied into the catalog stay (they're independent copies).
  fastify.delete("/resources/skill-repos/:id", async (request, reply) => {
    const { id } = request.params as { id: string };
    const record = settings.get().importedSkillRepositories.find((r) => r.id === id);
    if (!record) return reply.status(404).send({ error: "unknown skill repository" });
    try {
      rmSync(record.clonePath, { recursive: true, force: true, maxRetries: 5 });
    } catch {
      // Best-effort — a leftover clone dir is harmless.
    }
    settings.removeImportedSkillRepository(id);
    return { ok: true };
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
    // Drop the name from the flat default list only if it no longer resolves to
    // any prompt anywhere (another scope may still provide it).
    const globalPromptDir = nodePath.join(resourceHome(), ".pi", "agent", "prompts");
    const globalPromptExists = existsSync(nodePath.join(globalPromptDir, `${name}.md`));
    const stillResolves =
      globalPromptExists ||
      projects
        .list()
        .some((p) => existsSync(nodePath.join(p.path, ".pi", "prompts", `${name}.md`)));
    if (!stillResolves) settings.renameDefaultPromptTemplate(name, null);
    // Drop each project's assignment only if the name no longer resolves FOR THAT
    // project (the global was deleted and it has no own same-named prompt) — a
    // project that still has its own prompt keeps its assignment.
    for (const project of projects.list()) {
      if (!project.assignedPrompts?.includes(name)) continue;
      const resolvesForProject =
        globalPromptExists ||
        existsSync(nodePath.join(project.path, ".pi", "prompts", `${name}.md`));
      if (resolvesForProject) continue;
      projects.upsert({
        ...project,
        assignedPrompts: project.assignedPrompts.filter((p) => p !== name),
      });
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
    // Re-point references by which FILE each reference actually resolved to.
    // Prompts resolve GLOBAL-first (unlike skills, where a project skill shadows
    // the global), so:
    //  - A GLOBAL rename: every reference (the app-level defaults + every project
    //    assignment) resolved to that global, so re-point them all.
    //  - A PROJECT rename (in this request's project): only that project's own
    //    reference, and only when NO global of the same name shadowed it (else the
    //    reference resolved to the still-untouched global, not the renamed file).
    const globalPromptDir = nodePath.join(resourceHome(), ".pi", "agent", "prompts");
    const rewriteAssignment = (project: ProjectMeta): void => {
      projects.upsert({
        ...project,
        assignedPrompts: [
          ...new Set((project.assignedPrompts ?? []).map((p) => (p === name ? newName : p))),
        ],
      });
    };
    if (scope === "global") {
      // Defaults are a global concept, and every project assignment resolved to
      // this (now-renamed) global first.
      settings.renameDefaultPromptTemplate(name, newName);
      for (const project of projects.list()) {
        if (project.assignedPrompts?.includes(name)) rewriteAssignment(project);
      }
    } else {
      // Project rename: the global (if any) is untouched and would have shadowed
      // the reference, so only re-point this project's own assignment when no
      // global of that name exists. (A project prompt is never an app-level
      // default, so the default list is untouched here.)
      const globalShadows = existsSync(nodePath.join(globalPromptDir, `${name}.md`));
      if (!globalShadows) {
        const own = projects.list().find((p) => p.path === rootsFor(projectId).projectPath);
        if (own?.assignedPrompts?.includes(name)) rewriteAssignment(own);
      }
    }
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  // Extensions: user-added pi extension files (.ts/.js) merged into every
  // session's --extension list. Enable/disable without removing the entry.
  fastify.get("/resources/extensions", async (request) => {
    const projectId = (request.query as { projectId?: string }).projectId;
    const disabled = new Set(settings.get().disabledExtensions);
    // Merge the manually-added registry with the ones DISCOVERED in the standard
    // pi dirs (global + this project's), so a user sees their existing extensions
    // without adding each by hand. Deduped by absolute path; a discovered file
    // that was also added manually is shown once, marked as added.
    const registry = new Set(settings.get().extensions);
    const discovered = scanExtensions(rootsFor(projectId));
    const scopeByPath = new Map(discovered.map((e) => [e.path, e.scope]));
    const paths = [...new Set([...settings.get().extensions, ...discovered.map((e) => e.path)])];
    return {
      extensions: paths.map((filePath) => ({
        path: filePath,
        name: nodePath.basename(filePath),
        exists: existsSync(filePath),
        disabled: disabled.has(filePath),
        // Where it came from, so the UI can label it (native scope/source).
        scope: scopeByPath.get(filePath) ?? "global",
        source: registry.has(filePath) ? "added" : "discovered",
        // The app-bridge tool this extension re-registers (else null). A
        // conflicting extension is NOT injected (it would crash pi) — the UI
        // warns that the bridge shadows it (native conflict flag).
        bridgeConflict: extensionBridgeConflictAt(filePath),
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

  // The app's OWN generated bridge extensions (native "Agent Deck bridges" card):
  // a read-only inventory so a user SEES what Agent Deck injects into pi over the
  // bridge, separate from their own extensions. Live: each group's tools + active
  // state are derived from what's actually registered on the bridge right now, so
  // it reflects real config (memory off, no MCP server, etc.).
  const APP_BRIDGE_GROUPS = [
    {
      id: "memory",
      displayName: "Memory",
      summary: "Stores and recalls durable project memory the agent writes and reads.",
      condition: "When memory is enabled (AGENT_DECK_MEMORY≠0)",
      match: (name: string): boolean => name.startsWith("agent_deck_memory_"),
    },
    {
      id: "deck_agents",
      displayName: "Deck agents",
      summary:
        "Lets the agent delegate to your named agents (subagents), run them in parallel, and maintain a session plan; a subagent reports back over a supervisor channel.",
      condition: "Always on for parent sessions",
      match: (name: string): boolean =>
        [
          "managed_subagent",
          "managed_parallel",
          "set_session_plan",
          "update_session_plan",
        ].includes(name),
    },
    {
      id: "mcp",
      displayName: "MCP",
      summary: "Proxies your configured MCP servers' tools into sessions as mcp__<server>__<tool>.",
      condition: "When at least one MCP server is connected",
      match: (name: string): boolean => name.startsWith("mcp__"),
    },
  ];
  fastify.get("/runtime/bridges", async () => {
    const specs = bridge.specs();
    return {
      bridges: APP_BRIDGE_GROUPS.map((group) => {
        const toolNames = specs
          .filter((s) => group.match(s.name))
          .map((s) => s.name)
          .sort();
        return {
          id: group.id,
          displayName: group.displayName,
          summary: group.summary,
          condition: group.condition,
          toolNames,
          active: toolNames.length > 0,
        };
      }),
    };
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

  // Memory recall search (native Memory search 11.8): runs the SAME recall engine
  // the agent recalls with (recallMemories — lexical+fuzzy, or semantic when
  // opted in) and returns the ranked hits — active/pinned only, abstaining
  // (empty) when nothing matches.
  fastify.get("/memory/search", async (request, reply) => {
    const { projectId, q } = request.query as { projectId?: string; q?: string };
    const store = memoryStoreFor(projectId);
    if (!store) return reply.code(400).send({ error: "memory requires a known project" });
    const query = (q ?? "").trim();
    if (!query) return { memories: [] };
    return { memories: (await recallMemories(store, query)).map((hit) => hit.record) };
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
    // Augment each server with its OAuth state so the UI can show a Sign-in
    // affordance for authed http servers (stdio/anonymous servers stay "none").
    return {
      servers: mcp.status().map((server) => ({
        ...server,
        auth: server.transport === "http" ? mcpOAuth.state(server.id) : { status: "none" },
      })),
    };
  });

  // Begin OAuth for an authed http server: returns the authorization URL to open.
  // The browser redirect's code is submitted to /mcp/:id/login/callback.
  fastify.post("/mcp/:id/login", async (request, reply) => {
    const { id } = request.params as { id: string };
    const serverUrl = mcp.httpUrlFor(id);
    if (!serverUrl) return reply.code(404).send({ error: "unknown http MCP server" });
    const state = await mcpOAuth.beginAuth(id, serverUrl);
    if (state.status === "error") return reply.code(502).send({ error: state.error });
    return { auth: state };
  });

  // Complete OAuth with the code (and state, verified for CSRF) from the redirect,
  // then reconnect the server so its now-authorized tools register.
  const mcpCallbackBody = z.object({ code: z.string().min(1), state: z.string().optional() });
  fastify.post("/mcp/:id/login/callback", async (request, reply) => {
    const { id } = request.params as { id: string };
    const serverUrl = mcp.httpUrlFor(id);
    if (!serverUrl) return reply.code(404).send({ error: "unknown http MCP server" });
    const parsed = mcpCallbackBody.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.message });
    if (!mcpOAuth.verifyState(id, parsed.data.state)) {
      return reply.code(400).send({ error: "state mismatch (possible CSRF) — restart sign-in" });
    }
    const state = await mcpOAuth.submitCode(id, serverUrl, parsed.data.code);
    if (state.status !== "authorized")
      return reply.code(502).send({ error: state.error, auth: state });
    const server = await mcp.refresh(id);
    broadcast({ type: "resources_changed" });
    return { auth: state, server };
  });

  // Forget a server's OAuth tokens (logout), then reconnect so it drops to
  // unauthenticated + un-registers its tools.
  fastify.post("/mcp/:id/logout", async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!mcp.has(id)) return reply.code(404).send({ error: "unknown MCP server" });
    mcpOAuth.clear(id);
    await mcp.refresh(id);
    broadcast({ type: "resources_changed" });
    return { ok: true };
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

  // Provider auth (native provider-login surface): the OAuth-capable model
  // providers pi knows about, plus each one's sign-in status read from the
  // global ~/.pi/agent/auth.json. Interactive OAuth sign-in is a follow-up; this
  // covers the read side + logout (disconnect a stored credential).
  // Git automation (native GitRepositoryService): the working-tree status of a
  // project + commit-all. Push/remote is a follow-up. Project-scoped: git runs
  // in the project's path.
  fastify.get("/projects/:id/git/status", async (request, reply) => {
    const project = projects.find((p) => p.id === (request.params as { id: string }).id);
    if (!project) return reply.status(404).send({ error: "unknown project" });
    return gitStatus(project.path);
  });

  fastify.post("/projects/:id/git/commit", async (request, reply) => {
    const project = projects.find((p) => p.id === (request.params as { id: string }).id);
    if (!project) return reply.status(404).send({ error: "unknown project" });
    const parsed = z
      .object({
        message: z.string().trim().min(1, "a commit message is required").max(10_000),
        push: z.boolean().optional(),
      })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    try {
      await gitCommitAll(project.path, parsed.data.message);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (message === "nothing_to_commit") {
        return reply.status(400).send({ error: "There are no changes to commit." });
      }
      if (message === "not_a_repo") {
        return reply.status(400).send({ error: "This project isn't a git repository." });
      }
      return reply.status(500).send({ error: message });
    }
    // The commit landed; a subsequent push failure is reported separately so the
    // user knows the commit is safe locally even if the push didn't go out.
    if (parsed.data.push) {
      try {
        await gitPush(project.path);
      } catch (error) {
        broadcast({ type: "resources_changed" });
        return reply.status(502).send({
          error: `Committed, but the push failed: ${error instanceof Error ? error.message : String(error)}`,
          committed: true,
          pushed: false,
        });
      }
    }
    broadcast({ type: "resources_changed" });
    return { committed: true, pushed: parsed.data.push === true };
  });

  // Push the current branch (native pushCurrentBranch). Used on its own to push
  // already-made commits when the tree is clean.
  fastify.post("/projects/:id/git/push", async (request, reply) => {
    const project = projects.find((p) => p.id === (request.params as { id: string }).id);
    if (!project) return reply.status(404).send({ error: "unknown project" });
    try {
      await gitPush(project.path);
    } catch (error) {
      return reply
        .status(502)
        .send({ error: `Push failed: ${error instanceof Error ? error.message : String(error)}` });
    }
    return { pushed: true };
  });

  // Generate a commit message from the working-tree changes via a one-shot pi
  // helper (native PiAgentShipService.generateCommitMessage). No side effects —
  // it reads the diff, it doesn't stage or commit.
  fastify.post("/projects/:id/git/generate-message", async (request, reply) => {
    const project = projects.find((p) => p.id === (request.params as { id: string }).id);
    if (!project) return reply.status(404).send({ error: "unknown project" });
    let status: string;
    let diff: string;
    try {
      ({ status, diff } = await gitStatusAndDiff(project.path));
    } catch (error) {
      return reply.status(400).send({ error: String(error) });
    }
    if (!status) return reply.status(400).send({ error: "There are no changes to describe." });
    const defaults = envDefaults();
    try {
      const message = await sessions.runHelper({
        systemPrompt: COMMIT_MESSAGE_SYSTEM_PROMPT,
        userPrompt: `Generate a git commit message for these changes.\n\nGit status:\n${status}\n\nDiff:\n${diff}`,
        cwd: project.path,
        provider: defaults.provider,
        model: defaults.model,
        extensions: defaults.providerExtensions,
        env: defaults.env,
      });
      const trimmed = message.trim();
      if (!trimmed)
        return reply.status(502).send({ error: "The model returned an empty message." });
      return { message: trimmed };
    } catch (error) {
      return reply.status(502).send({
        error: `Couldn't generate a message: ${error instanceof Error ? error.message : String(error)}`,
      });
    }
  });

  // Loop definitions (native LoopDefinitionStore, Bank CRUD half — no run engine
  // yet). Global: loops live under ~/.pi/agent/loops.
  const loopEditBody = z.object({
    name: z.string().trim().min(1).max(200),
    description: z.string().max(2000).optional(),
    goal: z.string().max(50_000).optional(),
    structure: z
      .enum([
        "singleAgent",
        "makerChecker",
        "agentPipeline",
        "parallelAgents",
        "discoveryTriage",
        "humanApproval",
      ])
      .optional(),
    agentName: z.string().max(200).optional(),
    maxIterations: z.number().int().optional(),
    validationCommand: z.string().max(10_000).optional(),
    writeTarget: z.enum(["artifactMarkdown", "newWorktree", "currentCheckout"]).optional(),
  });

  fastify.get("/loops", async () => ({ loops: scanLoops(rootsFor()) }));

  fastify.put("/loops", async (request, reply) => {
    const parsed = loopEditBody.safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    try {
      writeLoopFile(rootsFor(), parsed.data);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (message === "loop_slug_conflict") {
        return reply
          .status(409)
          .send({ error: "Another loop already uses a name that resolves to the same file." });
      }
      return reply.status(500).send({ error: message });
    }
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  fastify.delete("/loops", async (request, reply) => {
    const parsed = z.object({ name: z.string().min(1) }).safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    deleteLoopFile(rootsFor(), parsed.data.name);
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  fastify.post("/loops/:name/duplicate", async (request, reply) => {
    const name = (request.params as { name: string }).name;
    try {
      const copyName = duplicateLoop(rootsFor(), name);
      broadcast({ type: "resources_changed" });
      return { name: copyName };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (message === "loop_not_found") {
        return reply.status(404).send({ error: `unknown loop: ${name}` });
      }
      return reply.status(500).send({ error: message });
    }
  });

  // Run a loop (native single-agent loop engine). Each iteration drives the
  // loop's agent to completion via a per-run parent session in the project cwd,
  // then runs the validation command; exit 0 stops the run successfully.
  fastify.post("/loops/:name/run", async (request, reply) => {
    const name = (request.params as { name: string }).name;
    const loop = scanLoops(rootsFor()).find((l) => l.name === name);
    if (!loop) return reply.status(404).send({ error: `unknown loop: ${name}` });
    const parsed = z
      .object({
        projectId: z.string().optional(),
        provider: z.string().optional(),
        model: z.string().optional(),
        extensions: z.array(z.string()).optional(),
        env: z.record(z.string()).optional(),
      })
      .safeParse(request.body ?? {});
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const body = parsed.data;
    const defaults = envDefaults();
    // A loop runs its agent + shell validation command in a project's working
    // tree — require an explicit project so it never executes in the server's cwd.
    if (!body.projectId) {
      return reply.status(400).send({ error: "projectId is required to run a loop" });
    }
    const project = projects.find((p) => p.id === body.projectId);
    if (!project) return reply.status(404).send({ error: "unknown project" });
    // writeTarget "newWorktree": run the loop in an isolated git worktree on a
    // fresh branch off the current one (native PiAgentSessionWorktreeService), so
    // the agent's work never touches the main checkout. The branch is kept after
    // the run; only the worktree directory is removed.
    let cwd = project.path;
    let worktree: GitWorktree | null = null;
    if (loop.writeTarget === "newWorktree") {
      const suffix = randomUUID().slice(0, 8);
      const target = nodePath.join(tmpdir(), `agent-deck-worktree-${suffix}`);
      try {
        const sourceBranch = await gitCurrentBranch(project.path);
        if (sourceBranch === "HEAD") throw new Error("detached HEAD — check out a branch first");
        const branch = `agent-deck/loop-${loop.name.replace(/[^A-Za-z0-9]+/g, "-")}-${suffix}`;
        await gitWorktreeAdd(project.path, target, branch, sourceBranch);
        worktree = { path: target, branch, sourceBranch };
        cwd = target;
      } catch (error) {
        // Best-effort: clean any partial worktree git created before failing.
        await gitWorktreeRemove(project.path, target);
        return reply.status(400).send({
          error: `Couldn't create a worktree for this loop: ${error instanceof Error ? error.message : String(error)}`,
        });
      }
    }
    // Default to the configured default + provider-registration extensions so a
    // plain run (just a projectId) still has its model provider registered.
    const baseExtensions = body.extensions ?? [
      ...(defaults.extensions ?? []),
      ...(defaults.providerExtensions ?? []),
    ];
    const finalizedBase = finalizeExtensions([
      ...baseExtensions,
      ...enabledExtensionPaths(body.projectId),
    ]);
    const parent = sessions.create({
      cwd,
      projectId: body.projectId,
      env: { ...defaults.env, ...body.env },
      plan: {
        kind: "parent",
        provider: body.provider ?? defaults.provider,
        model: body.model ?? defaults.model,
        extensions: finalizedBase.length > 0 ? finalizedBase : undefined,
      },
    });
    const run = loopEngine.start(loop, cwd, {
      projectId: body.projectId,
      executeAgent: (definition) =>
        sessions.runSubagent(parent.meta.id, definition.goal, definition.agentName || undefined),
    });
    // Tear down the transient parent session once the run reaches a terminal
    // state (whatever the outcome): stop the pi process AND drop it from the
    // session index/list so this internal helper never surfaces in the UI.
    void loopEngine.settled(run.id).finally(async () => {
      // Await destroy so the pi process has released the worktree dir before we
      // remove it (a live process would block the removal, esp. on Windows). A
      // destroy failure must not skip the rest of the cleanup.
      try {
        await sessions.destroy(parent.meta.id);
      } catch {
        // Best-effort — proceed with index/worktree cleanup regardless.
      }
      index.remove(parent.meta.id);
      bridgeTokens.delete(parent.meta.id);
      broadcast({ type: "session_removed", sessionId: parent.meta.id });
      // Remove the isolated worktree dir; its branch is kept so committed work
      // survives.
      if (worktree) await gitWorktreeRemove(project.path, worktree.path);
    });
    return reply.status(201).send({ run, worktree });
  });

  fastify.get("/loops/runs/:id", async (request, reply) => {
    const run = loopEngine.get((request.params as { id: string }).id);
    if (!run) return reply.status(404).send({ error: "unknown loop run" });
    return { run };
  });

  fastify.post("/loops/runs/:id/stop", async (request, reply) => {
    const run = loopEngine.get((request.params as { id: string }).id);
    if (!run) return reply.status(404).send({ error: "unknown loop run" });
    loopEngine.stop(run.id);
    return { ok: true };
  });

  fastify.get("/runtime/providers", async () => ({ providers: listProviders(rootsFor()) }));

  // Disconnect a stored provider credential (native logout). Only a known
  // provider id is accepted, so arbitrary keys can't be poked into auth.json.
  fastify.post("/runtime/providers/:id/logout", async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isKnownProvider(rootsFor(), id)) {
      return reply.status(404).send({ error: `unknown provider: ${id}` });
    }
    try {
      logoutProvider(rootsFor(), id);
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  // Interactive OAuth login (native PiProviderLoginService). start → a pollable
  // session that relays pi's AuthStorage.login callbacks (auth-url / device-code
  // / prompt / select / progress) to the client and threads responses back.
  fastify.post("/runtime/providers/:id/login", async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isKnownProvider(rootsFor(), id)) {
      return reply.status(404).send({ error: `unknown provider: ${id}` });
    }
    const loginId = providerLogin.start(rootsFor(), id);
    return reply.status(201).send({ loginId });
  });

  fastify.get("/runtime/providers/login/:loginId", async (request, reply) => {
    const { loginId } = request.params as { loginId: string };
    const since = Number((request.query as { since?: string }).since ?? 0);
    const result = providerLogin.poll(loginId, Number.isFinite(since) ? since : 0);
    if (!result) return reply.status(404).send({ error: "unknown login session" });
    // A finished login changes auth.json — nudge the Providers list to refresh.
    if (result.status === "done") broadcast({ type: "resources_changed" });
    return result;
  });

  fastify.post("/runtime/providers/login/:loginId/respond", async (request, reply) => {
    const { loginId } = request.params as { loginId: string };
    const parsed = z.object({ value: z.string().optional() }).safeParse(request.body ?? {});
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const ok = providerLogin.respond(loginId, parsed.data.value);
    return { ok };
  });

  fastify.post("/runtime/providers/login/:loginId/cancel", async (request) => {
    const { loginId } = request.params as { loginId: string };
    providerLogin.cancel(loginId);
    return { ok: true };
  });

  fastify.get("/settings", async () => ({ settings: settings.get() }));

  fastify.patch("/settings", async (request, reply) => {
    const parsed = z
      .object({
        defaultSkills: z.array(RESOURCE_NAME).optional(),
        /** Atomic membership ops — preferred over whole-array replacement. */
        setDefaultSkill: z.object({ name: RESOURCE_NAME, enabled: z.boolean() }).optional(),
        setDisabledSkill: z.object({ name: RESOURCE_NAME, disabled: z.boolean() }).optional(),
        setDefaultPromptTemplate: z
          .object({ name: RESOURCE_NAME, enabled: z.boolean() })
          .optional(),
        // Onboarding preferences (native OnboardingPreferencesView). null clears
        // defaultModel/defaultThinking back to "inherit the runtime default".
        autoTitle: z.boolean().optional(),
        worktreeIsolation: z.boolean().optional(),
        gitAutomation: z.boolean().optional(),
        defaultModel: z.string().min(1).nullable().optional(),
        defaultThinking: z
          .enum(["off", "minimal", "low", "medium", "high", "xhigh"])
          .nullable()
          .optional(),
        extensionLoadingMode: z.enum(["useMyExtensions", "agentDeckManaged"]).optional(),
      })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    if (parsed.data.setDefaultSkill) {
      const { name, enabled } = parsed.data.setDefaultSkill;
      return { settings: settings.setDefaultSkill(name, enabled) };
    }
    if (parsed.data.setDefaultPromptTemplate) {
      const { name, enabled } = parsed.data.setDefaultPromptTemplate;
      return { settings: settings.setDefaultPromptTemplate(name, enabled) };
    }
    if (parsed.data.setDisabledSkill) {
      const { name, disabled } = parsed.data.setDisabledSkill;
      const result = settings.setDisabledSkill(name, disabled);
      broadcast({ type: "resources_changed" }); // dims the row, updates assignment
      return { settings: result };
    }
    // Build a patch of ONLY the provided AppSettings fields — never spread
    // parsed.data directly (its undefined atomic-op keys would clobber existing
    // arrays like defaultSkills through the object spread in settings.update).
    const d = parsed.data;
    const patch: Partial<AppSettings> = {};
    if (d.defaultSkills !== undefined) patch.defaultSkills = d.defaultSkills;
    if (d.autoTitle !== undefined) patch.autoTitle = d.autoTitle;
    if (d.worktreeIsolation !== undefined) patch.worktreeIsolation = d.worktreeIsolation;
    if (d.gitAutomation !== undefined) patch.gitAutomation = d.gitAutomation;
    if (d.defaultModel !== undefined) patch.defaultModel = d.defaultModel;
    if (d.defaultThinking !== undefined) patch.defaultThinking = d.defaultThinking;
    if (d.extensionLoadingMode !== undefined) patch.extensionLoadingMode = d.extensionLoadingMode;
    return { settings: settings.update(patch) };
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
    if (parsed.data.assignedPrompts !== undefined)
      next.assignedPrompts = parsed.data.assignedPrompts;
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

  // Live token / cost / context-usage totals for a session (native session
  // context-usage indicator). Returns pi's get_session_stats verbatim; the
  // context-usage percent is null until the first LLM response.
  fastify.get("/sessions/:id/stats", async (request, reply) => {
    const { id } = request.params as { id: string };
    const session = sessions.get(id);
    if (!session) return reply.status(404).send({ error: "unknown session" });
    try {
      return { stats: await session.getSessionStats() };
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
          // assignees/author are included so the Issues screen can offer the
          // native client-side assignee + author facet filters (native
          // filteredBoardItems) and search over the already-loaded board
          // without a per-filter re-query.
          "number,title,state,url,labels,assignees,author,updatedAt",
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
        author?: { login: string } | null;
        updatedAt?: string;
      }>;
      return {
        issues: raw.map((i) => ({
          number: i.number,
          title: i.title,
          state: i.state,
          url: i.url,
          labels: (i.labels ?? []).map((l) => l.name),
          assignees: (i.assignees ?? []).map((a) => a.login),
          author: i.author?.login ?? null,
          updatedAt: i.updatedAt ?? null,
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

  // Content search across sessions (native Sessions search 18.1 "by title or
  // content"): scans each session's pi session file — the canonical transcript,
  // uniform for live and ended sessions — for the query. Title matching stays on
  // the client; this adds the content half, returning the matching session ids.
  fastify.get("/sessions/search", async (request) => {
    const q = String((request.query as { q?: string }).q ?? "")
      .trim()
      .toLowerCase();
    if (!q) return { ids: [] as string[] };
    const withFiles = index.list().filter((meta) => meta.piSessionFile);
    const ids: string[] = [];
    // Scan in bounded batches so a large session history can't exhaust file
    // descriptors (EMFILE). The message text is embedded as JSON string values,
    // so a lowercase substring match over the whole file finds it (it may
    // occasionally match structural JSON — an acceptable false-positive for a
    // free-text search).
    const BATCH = 24;
    for (let i = 0; i < withFiles.length; i += BATCH) {
      const hits = await Promise.all(
        withFiles.slice(i, i + BATCH).map(async (meta) => {
          try {
            const content = await readFile(meta.piSessionFile!, "utf8");
            return content.toLowerCase().includes(q) ? meta.id : null;
          } catch {
            return null; // unreadable / since-deleted file — skip
          }
        }),
      );
      for (const id of hits) if (id) ids.push(id);
    }
    return { ids };
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
    // A session with no pi session file never ran a turn (a draft, or an old
    // entry from before session files existed). It has nothing to restore, but
    // opening it should still work — sessions.resume launches a FRESH parent pi
    // (resumeSessionPath is undefined) with the session's project/agent context
    // and an empty transcript, rather than erroring.
    const defaults = envDefaults();
    try {
      const session = await sessions.resume(
        meta,
        {
          kind: "parent",
          resumeSessionPath: meta.piSessionFile,
          provider: defaults.provider,
          model: defaults.model,
          // Include provider-registration extensions so a session with no stored
          // launch plan (old/draft) still relaunches with its provider available.
          extensions: [...(defaults.extensions ?? []), ...(defaults.providerExtensions ?? [])],
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
    // Remove the session's isolated worktree (native: session-delete removes the
    // worktree). The BRANCH is deliberately kept so committed-but-unmerged work is
    // never lost (gitWorktreeRemove doesn't delete it). destroy() above awaited the
    // pi exit, so the checkout is no longer in use (matters on Windows).
    if (meta.worktreePath && meta.projectId) {
      const project = projects.find((p) => p.id === meta.projectId);
      if (project) await gitWorktreeRemove(project.path, meta.worktreePath).catch(() => {});
    }
    broadcast({ type: "session_removed", sessionId: id });
    return { ok: true };
  });

  // Merge an isolated session's worktree back into its source branch (native
  // Merge toolbar action): auto-commit the worktree's changes, then a --no-ff
  // merge into the source branch. The worktree + branch are kept (native default
  // keepWorktreeAfterMerge) so the user can keep iterating and merge again.
  fastify.post("/sessions/:id/merge", async (request, reply) => {
    const { id } = request.params as { id: string };
    const meta = sessions.get(id)?.meta ?? index.find((s) => s.id === id);
    if (!meta) return reply.status(404).send({ error: "unknown session" });
    const { worktreePath, worktreeBranch, worktreeSourceBranch, projectId } = meta;
    if (!worktreePath || !worktreeBranch || !worktreeSourceBranch) {
      return reply
        .status(400)
        .send({ error: "This session isn't running in an isolated worktree." });
    }
    const project = projectId ? projects.find((p) => p.id === projectId) : undefined;
    if (!project) return reply.status(404).send({ error: "unknown project" });

    // 1. Commit any uncommitted worktree work (native auto-commits first);
    //    nothing-to-commit is fine — earlier turns may already have committed.
    try {
      await gitCommitAll(worktreePath, `Agent Deck: ${meta.title ?? "session"} changes`);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (message !== "nothing_to_commit") {
        return reply
          .status(400)
          .send({ error: `Couldn't commit the worktree changes: ${gitErrorText(error)}` });
      }
    }
    // 2. Nothing ahead of the source branch → nothing to merge.
    const ahead = await gitCommitsAhead(project.path, worktreeBranch, worktreeSourceBranch).catch(
      () => 0,
    );
    if (ahead === 0) {
      return reply.status(400).send({ error: "Nothing to merge — the session made no commits." });
    }
    // 3. Merge into the source branch. A dirty parent tree / conflict surfaces
    //    the git stderr; the committed work stays safe on the session branch.
    try {
      await gitMerge(project.path, worktreeBranch, worktreeSourceBranch);
    } catch (error) {
      return reply.status(409).send({ error: `Merge failed: ${gitErrorText(error)}` });
    }
    return { ok: true, branch: worktreeBranch, sourceBranch: worktreeSourceBranch, commits: ahead };
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
    let project: ProjectMeta | undefined;
    if (body.projectId) {
      project = projects.find((p) => p.id === body.projectId);
      if (!project) return reply.status(404).send({ error: "unknown project" });
      cwd = project.path;
    }

    // Worktree isolation (native piAgentSessionsUseWorktree): when on and the
    // project is a git repo, run this session in its own worktree on a fresh
    // `agent-deck/session-<id>` branch so its work never touches the main
    // checkout — the Merge action brings it back. Best-effort: any failure (not
    // a repo, detached HEAD, git error) falls back to the project root.
    let worktree: GitWorktree | null = null;
    if (settings.get().worktreeIsolation && project && (await isGitRepo(project.path))) {
      const sourceBranch = await gitCurrentBranch(project.path).catch(() => "HEAD");
      if (sourceBranch !== "HEAD") {
        const suffix = randomUUID().slice(0, 8);
        const target = nodePath.join(worktreesRoot, suffix);
        const branch = `agent-deck/session-${suffix}`;
        try {
          mkdirSync(worktreesRoot, { recursive: true }); // git worktree add won't create missing parents
          await gitWorktreeAdd(project.path, target, branch, sourceBranch);
          worktree = { path: target, branch, sourceBranch };
          cwd = target;
        } catch {
          // Best-effort cleanup of any partial worktree; NEVER let it fail the
          // request — fall back to the project root (worktree stays null).
          await gitWorktreeRemove(project.path, target).catch(() => {});
        }
      }
    }

    // Resolve provider + model. Precedence: explicit request → the user's default
    // model (native onboarding preference) → env default. The default model is
    // stored provider-qualified ("provider:id") so it launches under the RIGHT
    // provider — a bare id can't disambiguate two providers exposing the same id.
    let provider = body.provider ?? defaults.provider;
    let model = body.model;
    if (model === undefined) {
      const defaultModel = settings.get().defaultModel; // "provider:id" | "id" | null
      if (defaultModel) {
        const sep = defaultModel.indexOf(":");
        if (sep > 0) {
          if (body.provider === undefined) provider = defaultModel.slice(0, sep);
          model = defaultModel.slice(sep + 1);
        } else {
          model = defaultModel; // unqualified — launch under the resolved provider
        }
      }
    }
    model = model ?? defaults.model;
    // Base extensions (request or env defaults) + the user's enabled ones,
    // deduped and re-validated as real files at launch time.
    const baseExtensions = body.extensions ?? defaults.extensions ?? [];
    const finalizedBase = finalizeExtensions([
      ...baseExtensions,
      ...enabledExtensionPaths(body.projectId),
    ]);
    const extensions = finalizedBase.length > 0 ? finalizedBase : undefined;

    // Default + project skill assignments become explicit --skill paths on
    // parent sessions (pi-rpc-launch-flags.md §1: "Default + current Project
    // skill assignments"). Applied at session creation; a running session
    // keeps its flags until relaunched.
    // CONTRACT GAP: bridge/audit/web extensions and APPEND_SYSTEM.md
    // preservation are still missing here (M2).
    let assignedSkillPaths: string[] | undefined;
    {
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

    // Prompt templates (native: defaultPromptTemplateNames ∪ the project's
    // assignedPromptTemplateNames): the user's "All Projects" defaults PLUS this
    // project's assigned prompts become `--prompt-template <path>` flags so pi
    // exposes them as /<name> slash commands. On a name collision we resolve to
    // the GLOBAL entry (first-wins) — matching pi's own prompt-template loader,
    // which loads global before project and keeps the first (unlike skills, where
    // a project skill deliberately shadows the global one). scanPrompts sorts a
    // same-named collision global-before-project, so keeping the first occurrence
    // yields the global file.
    let defaultPromptTemplatePaths: string[] | undefined;
    {
      const names = [...settings.get().defaultPromptTemplates, ...(project?.assignedPrompts ?? [])];
      if (names.length > 0) {
        const promptsByName = new Map<string, PromptInfo>();
        for (const prompt of scanPrompts(rootsFor(body.projectId))) {
          if (!promptsByName.has(prompt.name)) promptsByName.set(prompt.name, prompt);
        }
        const paths = [...new Set(names)]
          .map((name) => promptsByName.get(name)?.filePath)
          .filter((p): p is string => Boolean(p));
        if (paths.length > 0) defaultPromptTemplatePaths = paths;
      }
    }

    let plan: LaunchPlan = {
      kind: "parent",
      provider,
      model,
      // The user's default thinking level (native onboarding preference) seeds a
      // plain parent session; launchPlan encodes it as the `--model model:level`
      // suffix when a model is known, else `--thinking`.
      thinking: settings.get().defaultThinking ?? undefined,
      extensions,
      skills: body.skills ?? assignedSkillPaths,
      promptTemplates: defaultPromptTemplatePaths,
    };

    if (body.agentName) {
      // Agent-backed session: the picked agent's body becomes the system
      // prompt; frontmatter tools/skills/model apply per the launch contract.
      // Resolved via the same helper the subagent delegation uses, so both paths
      // stay in lock-step.
      const resolved = resolveNamedAgent(body.agentName, body.projectId);
      if (resolved.status === "not_found") {
        return reply.status(404).send({ error: `unknown agent: ${body.agentName}` });
      }
      if (resolved.status === "disabled") {
        return reply.status(409).send({ error: `agent is disabled: ${body.agentName}` });
      }
      const { agent } = resolved;
      plan = {
        kind: "agent",
        systemPrompt: { mode: agent.systemPromptMode, text: agent.body },
        tools: agent.tools,
        extensions: finalizeExtensions([...(extensions ?? []), ...agent.extensions]),
        skills: agent.skillDirs,
        provider,
        // Agent model/thinking, else the inherited defaults (frontmatter wins;
        // an agent that specifies neither falls back to the user's default model
        // AND default thinking, the same precedence a plain parent gets).
        model: agent.model ?? model,
        thinking: asThinkingLevel(agent.thinking) ?? settings.get().defaultThinking ?? undefined,
      };
    }

    const session = sessions.create({
      cwd,
      projectId: body.projectId,
      agentName: body.agentName,
      env: { ...defaults.env, ...body.env },
      plan,
      // Passed INTO create so the worktree fields land on the initial meta (and
      // its first persist) atomically with cwd — no window where cwd points at a
      // worktree that meta doesn't record.
      ...(worktree ? { worktree } : {}),
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
  // memories for the user's message (recallMemories — lexical+fuzzy, or semantic
  // when opted in) and return the top ones' full bodies as an injectable block
  // (empty → the hook injects nothing). The launch index carries only titles;
  // this surfaces the relevant bodies per turn.
  const RECALL_LIMIT = 4;
  async function handleRecall(
    sessionId: string,
    params: Record<string, unknown>,
  ): Promise<{ content: string }> {
    if (!memoryEnabled) return { content: "" };
    const query = typeof params.query === "string" ? params.query : "";
    const cwd = sessions.get(sessionId)?.meta.cwd;
    if (!cwd || !query.trim()) return { content: "" };
    const store: MemoryStore = { baseDir: memoryBaseDir, projectPath: cwd };
    const hits = await recallMemories(store, query, RECALL_LIMIT);
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
      return await handleRecall(parsed.data.sessionId, parsed.data.params);
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
