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
