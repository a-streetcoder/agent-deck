/**
 * Resource model shared by server and UI: agents and skills with the scope /
 * shadowing / filter semantics ported from the native app (SidebarModels.swift).
 *
 * Scope priority for same-name shadowing: project > global > library > builtin.
 */

export type ResourceScope = "builtin" | "global" | "library" | "project";

const SCOPE_PRIORITY: Record<ResourceScope, number> = {
  project: 3,
  global: 2,
  library: 1,
  builtin: 0,
};

export interface AgentInfo {
  name: string;
  description?: string;
  whenToUse?: string;
  model?: string;
  thinking?: string;
  systemPromptMode: "replace" | "append";
  tools?: string[];
  skills?: string[];
  extensions?: string[];
  /** MCP server names (from mcp.json) this agent declares for its sessions. */
  mcpServers?: string[];
  scope: ResourceScope;
  filePath: string;
  /** Markdown body = the agent system prompt. */
  body: string;
  /** A higher-priority scope defines the same name. */
  shadowed: boolean;
  /** Effective agent that hides a builtin of the same name. */
  replacesBuiltin: boolean;
  /** Builtin whose values come partly from settings.json agentOverrides. */
  overridden?: boolean;
  /** Disabled agents are excluded from the picker and won't launch. */
  disabled?: boolean;
}

export interface SkillInfo {
  name: string;
  description: string;
  scope: ResourceScope;
  filePath: string;
  baseDir: string;
  disableModelInvocation: boolean;
  /** SKILL.md markdown body (frontmatter stripped) — the editor's initial state. */
  body: string;
  /** App-level disable: dimmed, unassignable, excluded from --skill injection. */
  disabled?: boolean;
}

export interface PromptInfo {
  name: string;
  description?: string;
  scope: ResourceScope;
  filePath: string;
  /** Markdown body (frontmatter stripped) — the editor's initial state. */
  body: string;
  /**
   * The slash command that runs this template (native prompt.invocation).
   * pi matches `/<filename>` (expandPromptTemplate compares against the file's
   * basename, NOT any frontmatter `name`), so this is `/` + the basename.
   */
  invocation: string;
  /** pi's `argument-hint` frontmatter — a usage hint shown next to the command. */
  argumentHint?: string;
}

export type AgentFilter =
  | "all"
  | "builtin"
  | "global"
  | "library"
  | "project"
  | "overridden"
  | "replaced"
  | "custom"
  | "disabled";

export const AGENT_FILTERS: AgentFilter[] = [
  "all",
  "builtin",
  "global",
  "library",
  "project",
  "overridden",
  "replaced",
  "custom",
  "disabled",
];

export function agentMatchesFilter(agent: AgentInfo, filter: AgentFilter): boolean {
  switch (filter) {
    case "all":
      return true;
    case "builtin":
    case "global":
    case "library":
    case "project":
      return agent.scope === filter;
    case "overridden":
      // A builtin whose values are partly redefined by a settings.json override.
      return agent.overridden === true;
    case "replaced":
      return agent.replacesBuiltin || (agent.scope === "builtin" && agent.shadowed);
    case "custom":
      return agent.scope !== "builtin";
    case "disabled":
      return agent.disabled === true;
  }
}

/** Compute shadowing flags across all scanned agents (pure; stable order). */
export function applyShadowing(
  agents: Omit<AgentInfo, "shadowed" | "replacesBuiltin">[],
): AgentInfo[] {
  const best = new Map<string, number>();
  const hasBuiltin = new Set<string>();
  for (const agent of agents) {
    const priority = SCOPE_PRIORITY[agent.scope];
    if (agent.scope === "builtin") hasBuiltin.add(agent.name);
    const current = best.get(agent.name);
    if (current === undefined || priority > current) best.set(agent.name, priority);
  }
  return agents.map((agent) => {
    const priority = SCOPE_PRIORITY[agent.scope];
    const shadowed = best.get(agent.name)! > priority;
    return {
      ...agent,
      shadowed,
      replacesBuiltin: !shadowed && agent.scope !== "builtin" && hasBuiltin.has(agent.name),
    };
  });
}
