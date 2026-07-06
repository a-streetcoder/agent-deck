import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { listMemories, type MemoryStore } from "@agent-deck/memory";
import {
  MOCK_MODEL_ID,
  MOCK_PROVIDER_ID,
  startMockProvider,
  writeMockProviderExtension,
  type MockProviderServer,
} from "@agent-deck/testkit";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * Memory end-to-end through real pi (permanent CI guard): the native memory
 * tools are registered on the bridge, so a real pi session can call
 * agent_deck_memory_write to persist a project fact and agent_deck_memory_search
 * to recall it — the fact lands in the project-scoped Markdown store and its
 * body flows back to the model.
 */

process.env.AGENT_DECK_TEST = "1";

let mock: MockProviderServer;
let server: AgentDeckServer;

const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const cwd = mkdtempSync(path.join(tmpdir(), "pi-mem-project-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));

beforeAll(async () => {
  // Drive two tool calls in one turn: first write the memory, then search it,
  // then answer with text — keyed on how many tool results are already present.
  mock = await startMockProvider({
    toolCall: (_lastUser, body) => {
      const toolResults = body.messages.filter((m) => m.role === "tool").length;
      if (toolResults === 0) {
        return {
          name: "agent_deck_memory_write",
          arguments: {
            type: "decision",
            title: "Package manager",
            summary: "The monorepo uses pnpm workspaces",
            body: "We use pnpm, not npm or yarn — the workspace protocol links packages.",
          },
        };
      }
      if (toolResults === 1) {
        return { name: "agent_deck_memory_search", arguments: { query: "which package manager" } };
      }
      return null;
    },
    reply: () => "Recorded and recalled the package-manager decision.",
  });
  server = await startServer({ dataDir });
});

afterAll(async () => {
  await server.close();
  await mock.close();
});

describe("memory: write + recall through real pi tools", () => {
  it("persists a memory to the project store and recalls its body to the model", async () => {
    const response = await fetch(`http://127.0.0.1:${server.port}/sessions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        cwd,
        provider: MOCK_PROVIDER_ID,
        model: MOCK_MODEL_ID,
        extensions: [writeMockProviderExtension(mock.baseUrl)],
        env: { HOME: tmpHome, USERPROFILE: tmpHome, PI_SKIP_VERSION_CHECK: "1" },
      }),
    });
    expect(response.status).toBe(201);
    const { session } = (await response.json()) as { session: { id: string } };

    await server.sessions.get(session.id)!.prompt("remember our package manager, then recall it");
    await server.receipts.waitFor("idle", session.id);

    // The memory landed in the project-scoped store.
    const store: MemoryStore = { baseDir: path.join(dataDir, "memory"), projectPath: cwd };
    const memories = listMemories(store);
    expect(memories).toHaveLength(1);
    expect(memories[0]).toMatchObject({ type: "decision", title: "Package manager" });

    // The search tool fed the memory body back to the model (a role:"tool"
    // message on the final provider request carries the stored content).
    const followUp = mock.requests[mock.requests.length - 1]!;
    const toolText = JSON.stringify(followUp.messages.filter((m) => m.role === "tool"));
    expect(toolText).toContain("workspace protocol links packages");
  });
});
