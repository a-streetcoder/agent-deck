import nodePath from "node:path";
import type { ServerMessage } from "@agent-deck/contracts";
import type { MemorySearchHit, MemoryStore } from "@agent-deck/memory";
import type { ProviderLoginManager, ResourceRoots } from "@agent-deck/resources";
import type { FastifyInstance } from "fastify";
import type { BridgeRegistry } from "./bridge.ts";
import type { LoopEngine } from "./loopEngine.ts";
import type { McpManager } from "./mcpTools.ts";
import type { McpOAuthCoordinator } from "./mcpOAuth.ts";
import type { ProjectIndex, SessionIndex, SettingsStore } from "./persistence.ts";
import type { AgentSessionPlan, SessionManager } from "./SessionManager.ts";
import type { SupervisorLog } from "./supervisor.ts";

const THINKING_LEVELS = new Set(["off", "minimal", "low", "medium", "high", "xhigh"]);

export function asThinkingLevel(value: string | undefined): AgentSessionPlan["thinking"] {
  return value && THINKING_LEVELS.has(value) ? (value as AgentSessionPlan["thinking"]) : undefined;
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
export function envDefaults(): {
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

export interface NamedAgentLaunch {
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

/**
 * Everything a route module needs from the composition root. Assembled once in
 * startServer (server.ts) and handed to each register function; the modules
 * destructure what they use, so the moved handler bodies read exactly as they
 * did in the monolith.
 */
export interface ServerContext {
  fastify: FastifyInstance;
  sessions: SessionManager;
  index: SessionIndex;
  projects: ProjectIndex;
  settings: SettingsStore;
  bridge: BridgeRegistry;
  bridgeTokens: Map<string, string>;
  supervisor: SupervisorLog;
  childSupervisors: Map<string, { parentSessionId: string; cellId: string }>;
  pendingSupervisor: Map<
    string,
    {
      parentSessionId: string;
      childSessionId: string;
      settle: (result: { content: string; isError?: boolean }) => void;
    }
  >;
  loopEngine: LoopEngine;
  providerLogin: ProviderLoginManager;
  mcp: McpManager;
  mcpOAuth: McpOAuthCoordinator;
  memoryEnabled: boolean;
  memoryBaseDir: string;
  worktreesRoot: string;
  skillReposRoot: string;
  recallMemories(store: MemoryStore, query: string, limit?: number): Promise<MemorySearchHit[]>;
  resolveNamedAgent(
    name: string,
    projectId?: string,
  ): { status: "ok"; agent: NamedAgentLaunch } | { status: "not_found" } | { status: "disabled" };
  extensionBridgeConflictAt(filePath: string): string | null;
  enabledExtensionPaths(projectId?: string): string[];
  resourceHome(): string;
  rootsFor(projectId?: string): ResourceRoots;
  broadcast(message: ServerMessage): void;
  watchProject(projectPath: string): void;
}
