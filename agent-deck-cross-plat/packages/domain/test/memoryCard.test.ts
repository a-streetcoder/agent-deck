import { describe, expect, it } from "vitest";
import { memoryToolCardLabel } from "../src/transcript.ts";

const base = { status: "done" as const, result: undefined as unknown };

describe("memoryToolCardLabel", () => {
  it("returns null for non-memory tools", () => {
    expect(memoryToolCardLabel({ ...base, toolName: "bash" })).toBeNull();
    expect(memoryToolCardLabel({ ...base, toolName: "read" })).toBeNull();
  });

  it("labels search and mark-stale by tool name", () => {
    expect(memoryToolCardLabel({ ...base, toolName: "agent_deck_memory_search" })).toBe(
      "Memory Searched",
    );
    expect(memoryToolCardLabel({ ...base, toolName: "agent_deck_memory_mark_stale" })).toBe(
      "Memory Marked Stale",
    );
  });

  it("distinguishes stored / edited / blocked for write", () => {
    const write = (status: "done" | "error", result: unknown) =>
      memoryToolCardLabel({ toolName: "agent_deck_memory_write", status, result });

    expect(write("done", "Stored memory mem_1: Use pnpm")).toBe("Memory Stored");
    expect(write("done", "Updated memory mem_1: Use pnpm")).toBe("Memory Edited");
    // A held near-duplicate write comes back non-error with a guidance message.
    expect(write("done", 'This looks like a near-duplicate of "X" (id mem_2).')).toBe(
      "Memory Blocked",
    );
    // A secret/no-project write is an error.
    expect(write("error", "Write blocked: contains a secret")).toBe("Memory Blocked");
    // No result yet (still running) defaults to Stored.
    expect(write("done", undefined)).toBe("Memory Stored");
    // The memory TITLE is interpolated into the result — a title containing
    // "updated" / "blocked" / "secret" must NOT flip the label (prefix match).
    expect(write("done", "Stored memory mem_3: The updated deploy runbook")).toBe("Memory Stored");
    expect(write("done", "Stored memory mem_4: How we blocked the secret leak")).toBe(
      "Memory Stored",
    );
  });
});
