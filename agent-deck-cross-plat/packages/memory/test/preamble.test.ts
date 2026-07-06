import { describe, expect, it } from "vitest";
import { buildMemoryPreamble } from "../src/preamble.ts";

describe("memory preamble", () => {
  it("fences the policy and lists the index lines when memories exist", () => {
    const block = buildMemoryPreamble({
      lines: ["mem_1 · decision · Use pnpm — the monorepo uses pnpm workspaces"],
      overflow: 0,
    });
    expect(block).toContain('<memory-context source="Agent Deck" scope="project">');
    expect(block).toContain("</memory-context>");
    expect(block).toContain("agent_deck_memory_write");
    expect(block).toContain("mem_1 · decision · Use pnpm");
    // Policy makes the update-not-duplicate rule explicit.
    expect(block).toMatch(/update an existing memory by its id/i);
  });

  it("states the index is empty when nothing is stored", () => {
    const block = buildMemoryPreamble({ lines: [], overflow: 0 });
    expect(block).toContain("empty — nothing stored yet");
    // The policy is still present so the agent knows the tools exist.
    expect(block).toContain("agent_deck_memory_search");
  });

  it("notes overflow when the index is capped", () => {
    const block = buildMemoryPreamble({ lines: ["mem_a · context · A — a"], overflow: 12 });
    expect(block).toContain("and 12 more");
  });
});
