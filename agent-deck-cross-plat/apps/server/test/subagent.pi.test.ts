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
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * Native subagents, first slice (native-subagent-bridge.md), end-to-end against
 * real pi: a parent session calls managed_subagent{task}; the server launches a
 * fresh child pi (inheriting the parent's provider), runs the task, and returns
 * the child's final text to the parent as the tool result. Proves the parent →
 * child → parent round-trip.
 */

process.env.AGENT_DECK_TEST = "1";

let mock: MockProviderServer;
let server: AgentDeckServer;
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const cwd = mkdtempSync(path.join(tmpdir(), "pi-subagent-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));

function systemText(request: ChatCompletionRequest): string {
  return request.messages
    .filter((m) => m.role === "developer" || m.role === "system")
    .map((m) => (typeof m.content === "string" ? m.content : JSON.stringify(m.content)))
    .join("\n");
}

/** The child is identifiable by its subagent system prompt. */
function isChildRequest(body: ChatCompletionRequest): boolean {
  return systemText(body).includes("focused subagent launched by Agent Deck");
}

beforeAll(async () => {
  mock = await startMockProvider({
    // Only the PARENT (not the child, and only before it has the result) delegates.
    toolCall: (_lastUser, body) => {
      if (isChildRequest(body) || body.messages.some((m) => m.role === "tool")) return null;
      return { name: "managed_subagent", arguments: { task: "Summarize the meeting notes." } };
    },
    // The child produces a distinctive result; the parent replies plainly.
    reply: (_lastUser, body) =>
      isChildRequest(body)
        ? "CHILD_SUBAGENT_SENTINEL: three bullet summary."
        : "Delegated and done.",
  });
  // The child (like the title helper) loads only provider-registration extensions
  // from AGENT_DECK_PROVIDER_EXTENSIONS, so point that at the mock provider too.
  process.env.AGENT_DECK_PROVIDER_EXTENSIONS = writeMockProviderExtension(mock.baseUrl);
  server = await startServer({ dataDir });
});

afterAll(async () => {
  await server.close();
  await mock.close();
  delete process.env.AGENT_DECK_PROVIDER_EXTENSIONS;
});

describe("managed_subagent: a parent spawns a child and gets its result", () => {
  it("runs a child pi session and returns its output to the parent", async () => {
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

    await server.sessions.get(session.id)!.prompt("delegate the summary task");
    await server.receipts.waitFor("idle", session.id);

    // A child request actually hit the provider (the subagent really ran).
    expect(mock.requests.some(isChildRequest)).toBe(true);

    // The parent received the child's output via the managed_subagent tool result.
    const followUp = mock.requests[mock.requests.length - 1]!;
    const toolText = JSON.stringify(followUp.messages.filter((m) => m.role === "tool"));
    expect(toolText).toContain("CHILD_SUBAGENT_SENTINEL: three bullet summary.");
  });
});
