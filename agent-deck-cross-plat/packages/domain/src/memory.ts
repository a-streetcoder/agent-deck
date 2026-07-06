/**
 * Memory presentation helpers shared by the UI. The store (packages/memory)
 * owns persistence; this is the view model the MemoryScreen groups by (native
 * MemoryScreen §11.1: Pinned / Active / Stale / Archived sections).
 */

export type MemoryStatus = "pinned" | "active" | "stale" | "archived";

/** Section order: injected first (pinned, active), then kept-but-not-injected. */
export const MEMORY_STATUS_ORDER: MemoryStatus[] = ["pinned", "active", "stale", "archived"];

export const MEMORY_STATUS_LABEL: Record<MemoryStatus, string> = {
  pinned: "Pinned",
  active: "Active",
  stale: "Stale",
  archived: "Archived",
};

export interface MemoryStatusGroup<T> {
  status: MemoryStatus;
  label: string;
  memories: T[];
}

/**
 * Group memories into ordered status sections, preserving each memory's
 * relative order within its section and dropping empty sections. Any memory
 * whose status isn't a known section is skipped (defensive against drift).
 */
export function groupMemoriesByStatus<T extends { status: MemoryStatus }>(
  memories: T[],
): MemoryStatusGroup<T>[] {
  return MEMORY_STATUS_ORDER.map((status) => ({
    status,
    label: MEMORY_STATUS_LABEL[status],
    memories: memories.filter((m) => m.status === status),
  })).filter((group) => group.memories.length > 0);
}
