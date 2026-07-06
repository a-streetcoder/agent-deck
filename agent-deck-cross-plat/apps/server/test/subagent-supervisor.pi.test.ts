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
 * Supervisor channel (native-subagent-bridge.md), non-blocking progress_update:
 * a child subagent calls contact_supervisor{method:"progress_update"}; the server
 * records it AND streams it into the parent's Subagent card — while the child's
 * final text still comes back to the model unchanged.
 */

process.env.AGENT_DECK_TEST = "1";

let mock: MockProviderServer;
let server: AgentDeckServer;
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const cwd = mkdtempSync(path.join(tmpdir(), "pi-supervisor-"));
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
      const hasToolResult = body.messages.some((m) => m.role === "tool");
      if (isChildRequest(body)) {
        // The child first reports progress, then (after the ack) replies with text.
        return hasToolResult
          ? null
          : {
              name: "contact_supervisor",
              arguments: { method: "progress_update", message: "PROGRESS_SENTINEL: halfway there" },
            };
      }
      // The parent delegates once, then replies plainly.
      return hasToolResult
        ? null
        : { name: "managed_subagent", arguments: { task: "Do the thing." } };
    },
    reply: (_lastUser, body) =>
      isChildRequest(body) ? "CHILD_FINAL_SENTINEL: complete." : "Delegated and done.",
  });
  process.env.AGENT_DECK_PROVIDER_EXTENSIONS = writeMockProviderExtension(mock.baseUrl);
  server = await startServer({ dataDir });
});

afterAll(async () => {
  await server.close();
  await mock.close();
  delete process.env.AGENT_DECK_PROVIDER_EXTENSIONS;
});

describe("contact_supervisor: a child reports non-blocking progress to its parent", () => {
  it("records the progress and shows it on the parent card while returning the result", async () => {
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
    await managed.prompt("delegate with progress reporting");
    await server.receipts.waitFor("idle", session.id);

    // The child's progress update was recorded server-side, keyed to the parent.
    const recorded = server.supervisor.list(session.id);
    expect(recorded).toHaveLength(1);
    expect(recorded[0]!.method).toBe("progress_update");
    expect(recorded[0]!.message).toBe("PROGRESS_SENTINEL: halfway there");

    // The parent's Subagent card shows the progress AND finished with the result.
    const subagentCells = managed
      .snapshot()
      .state.cells.filter((c): c is SubagentCell => c.kind === "subagent");
    expect(subagentCells).toHaveLength(1);
    expect(subagentCells[0]!.status).toBe("done");
    expect(subagentCells[0]!.progress).toContain("PROGRESS_SENTINEL: halfway there");
    expect(subagentCells[0]!.text).toContain("CHILD_FINAL_SENTINEL: complete.");

    // The model still received the child's final text as the managed_subagent result.
    const followUp = mock.requests[mock.requests.length - 1]!;
    const toolText = JSON.stringify(followUp.messages.filter((m) => m.role === "tool"));
    expect(toolText).toContain("CHILD_FINAL_SENTINEL: complete.");
  });
});
