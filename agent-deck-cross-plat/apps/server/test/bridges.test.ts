import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * The read-only "Agent Deck bridges" inventory (native bridgesCard): GET
 * /runtime/bridges reports which app-generated bridges are injected, derived
 * live from what's actually registered on the bridge (so memory-off / no-MCP is
 * reflected honestly).
 */

process.env.AGENT_DECK_TEST = "1";

let server: AgentDeckServer | undefined;

afterEach(async () => {
  await server?.close();
  server = undefined;
  delete process.env.AGENT_DECK_MEMORY;
});

async function bridges(): Promise<Array<{ id: string; active: boolean; toolNames: string[] }>> {
  const res = await fetch(`http://127.0.0.1:${server!.port}/runtime/bridges`);
  const { bridges } = (await res.json()) as {
    bridges: Array<{ id: string; active: boolean; toolNames: string[] }>;
  };
  return bridges;
}

describe("GET /runtime/bridges", () => {
  it("reports memory + deck-agent bridges active with their tools, and MCP inactive with no server", async () => {
    server = await startServer({ dataDir: mkdtempSync(path.join(tmpdir(), "agent-deck-data-")) });
    const list = await bridges();

    const memory = list.find((b) => b.id === "memory");
    expect(memory?.active).toBe(true);
    expect(memory?.toolNames).toEqual(
      expect.arrayContaining([
        "agent_deck_memory_write",
        "agent_deck_memory_search",
        "agent_deck_memory_mark_stale",
      ]),
    );

    const deckAgents = list.find((b) => b.id === "deck_agents");
    expect(deckAgents?.active).toBe(true);
    expect(deckAgents?.toolNames).toEqual(
      expect.arrayContaining(["managed_subagent", "managed_parallel"]),
    );

    // No MCP server connected → the MCP bridge is present but inactive.
    const mcp = list.find((b) => b.id === "mcp");
    expect(mcp?.active).toBe(false);
    expect(mcp?.toolNames).toEqual([]);
  });

  it("reports the memory bridge OFF when memory is disabled", async () => {
    process.env.AGENT_DECK_MEMORY = "0";
    server = await startServer({ dataDir: mkdtempSync(path.join(tmpdir(), "agent-deck-data-")) });
    const memory = (await bridges()).find((b) => b.id === "memory");
    expect(memory?.active).toBe(false);
    expect(memory?.toolNames).toEqual([]);
  });
});
