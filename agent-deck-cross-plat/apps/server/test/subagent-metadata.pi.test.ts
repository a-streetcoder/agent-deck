import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  MOCK_MODEL_ID,
  MOCK_PROVIDER_ID,
  startMockProvider,
  writeMockProviderExtension,
  type ChatCompletionRequest,
  type MockProviderServer,
} from "@agent-deck/testkit";
import type { SubagentCell } from "@agent-deck/domain";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * Deck per-run metadata: a completed subagent cell carries the child's model,
 * token usage, and wall-clock duration (cross-plat echo of the native
 * PiSubagentRunRecord metrics), captured from the child's final assistant turn.
 */

process.env.AGENT_DECK_TEST = "1";

let mock: MockProviderServer;
let server: AgentDeckServer;
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const cwd = mkdtempSync(path.join(tmpdir(), "pi-subagent-meta-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));

function systemText(request: ChatCompletionRequest): string {
  return request.messages
    .filter((m) => m.role === "developer" || m.role === "system")
    .map((m) => (typeof m.content === "string" ? m.content : JSON.stringify(m.content)))
    .join("\n");
}

function isChildRequest(body: ChatCompletionRequest): boolean {
  return systemText(body).includes("focused subagent launched by Agent Deck");
}

beforeAll(async () => {
  mock = await startMockProvider({
    toolCall: (_lastUser, body) => {
      if (isChildRequest(body) || body.messages.some((m) => m.role === "tool")) return null;
      return { name: "managed_subagent", arguments: { task: "Summarize." } };
    },
    // A multi-word child reply so the mock reports completion (output) tokens > 0.
    reply: (_lastUser, body) =>
      isChildRequest(body) ? "one two three four five" : "Delegated and done.",
  });
  process.env.AGENT_DECK_PROVIDER_EXTENSIONS = writeMockProviderExtension(mock.baseUrl);
  server = await startServer({ dataDir });
});

afterAll(async () => {
  await server.close();
  await mock.close();
  delete process.env.AGENT_DECK_PROVIDER_EXTENSIONS;
});

describe("subagent run metadata: model + tokens + duration on the done cell", () => {
  it("captures the child's model, usage, and duration onto the finished subagent cell", async () => {
    const response = await fetch(`http://127.0.0.1:${server.port}/sessions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        cwd,
        provider: MOCK_PROVIDER_ID,
        model: MOCK_MODEL_ID,
        extensions: [process.env.AGENT_DECK_PROVIDER_EXTENSIONS],
        env: { HOME: tmpHome, USERPROFILE: tmpHome, PI_SKIP_VERSION_CHECK: "1" },
      }),
    });
    expect(response.status).toBe(201);
    const { session } = (await response.json()) as { session: { id: string } };
    const managed = server.sessions.get(session.id)!;

    await managed.prompt("delegate the summary");
    await server.receipts.waitFor("idle", session.id);

    const subagent = managed
      .snapshot()
      .state.cells.find((c): c is SubagentCell => c.kind === "subagent")!;
    expect(subagent.status).toBe("done");
    // Model the child ran under.
    expect(subagent.model).toBe(MOCK_MODEL_ID);
    // Wall-clock duration is a positive number of ms.
    expect(typeof subagent.durationMs).toBe("number");
    expect(subagent.durationMs!).toBeGreaterThan(0);
    // Token usage from the mock provider (prompt=1, completion=word count).
    expect(typeof subagent.inputTokens).toBe("number");
    expect(subagent.inputTokens!).toBeGreaterThanOrEqual(0);
    expect(subagent.outputTokens!).toBeGreaterThan(0);
  });
});
