/**
 * Extension conflict detection (native Extensions screen §16.2: conflict rows
 * are visibly flagged). pi loads each --extension by resolved path, so two
 * ENABLED extensions with the same filename both load — not a pi-level clash,
 * but a suspicious duplicate that's almost always a mistake (the same logical
 * extension added from two locations). Disabled ones aren't loaded → no flag.
 */

export interface ExtensionConflictInput {
  /** The extension's filename (basename) — how pi identifies it. */
  name: string;
  disabled: boolean;
}

/**
 * Names loaded by more than one ENABLED extension. An enabled row whose name is
 * in this set collides with another enabled row of the same name.
 */
export function conflictingExtensionNames(entries: ExtensionConflictInput[]): Set<string> {
  const enabledCounts = new Map<string, number>();
  for (const entry of entries) {
    if (entry.disabled) continue;
    enabledCounts.set(entry.name, (enabledCounts.get(entry.name) ?? 0) + 1);
  }
  const conflicts = new Set<string>();
  for (const [name, count] of enabledCounts) {
    if (count > 1) conflicts.add(name);
  }
  return conflicts;
}

/**
 * Tool names the app injects through its OWN generated bridge extensions
 * (memory, subagents, ask-user, session plan). pi HARD-FAILS to launch if two
 * extensions register the same tool name — so a user extension (discovered or
 * added) that registers one of these both shadows the bridge AND would crash the
 * session if injected. Native flags this (PiExtensionConflictDetector); the port
 * both flags it and excludes the extension from the launch so it can't crash.
 */
export const BRIDGE_TOOL_NAMES: readonly string[] = [
  "agent_deck_memory_write",
  "agent_deck_memory_search",
  "agent_deck_memory_mark_stale",
  "managed_subagent",
  "managed_parallel",
  "contact_supervisor",
  "ask_user",
  "set_session_plan",
  "update_session_plan",
];

/**
 * The first app-bridge tool an extension's SOURCE registers (as a quoted string
 * literal — native's PiExtensionConflictDetector heuristic), else null. Also
 * catches the `mcp__` proxy-tool prefix. Source-text based: no code is executed.
 */
export function extensionBridgeConflict(source: string): string | null {
  for (const tool of BRIDGE_TOOL_NAMES) {
    if (new RegExp(`['"\`]${tool}['"\`]`).test(source)) return tool;
  }
  // Any mcp__<server>__<tool> literal collides with the MCP proxy's tools.
  const mcp = /['"`](mcp__[A-Za-z0-9_]+__[A-Za-z0-9_]+)['"`]/.exec(source);
  return mcp ? mcp[1]! : null;
}
