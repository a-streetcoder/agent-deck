import { describe, expect, it } from "vitest";
import { groupMemoriesByStatus, type MemoryStatus } from "../src/memory.ts";

/**
 * MemoryScreen status sections (native §11.1: Pinned / Active / Stale /
 * Archived). Pure view-model grouping shared by the UI.
 */

function mem(id: string, status: MemoryStatus): { id: string; status: MemoryStatus } {
  return { id, status };
}

describe("groupMemoriesByStatus", () => {
  it("orders sections pinned → active → stale → archived and drops empties", () => {
    const groups = groupMemoriesByStatus([
      mem("a", "active"),
      mem("s", "stale"),
      mem("p", "pinned"),
    ]);
    // No archived memories → no archived section.
    expect(groups.map((g) => g.status)).toEqual(["pinned", "active", "stale"]);
    expect(groups.map((g) => g.label)).toEqual(["Pinned", "Active", "Stale"]);
    expect(groups.find((g) => g.status === "pinned")!.memories.map((m) => m.id)).toEqual(["p"]);
  });

  it("preserves each memory's relative order within its section", () => {
    const groups = groupMemoriesByStatus([
      mem("a1", "active"),
      mem("p1", "pinned"),
      mem("a2", "active"),
      mem("a3", "active"),
    ]);
    expect(groups.find((g) => g.status === "active")!.memories.map((m) => m.id)).toEqual([
      "a1",
      "a2",
      "a3",
    ]);
  });

  it("returns no sections for an empty list", () => {
    expect(groupMemoriesByStatus([])).toEqual([]);
  });

  it("skips a memory with an unknown status rather than crashing", () => {
    const groups = groupMemoriesByStatus([
      mem("ok", "active"),
      { id: "weird", status: "bogus" as MemoryStatus },
    ]);
    expect(groups).toHaveLength(1);
    expect(groups[0]!.memories.map((m) => m.id)).toEqual(["ok"]);
  });
});
