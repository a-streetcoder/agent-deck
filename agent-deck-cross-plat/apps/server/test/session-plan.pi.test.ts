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
 * Session activity plan (native activity-sidebar): a parent agent calls
 * set_session_plan to establish a checklist, then update_session_plan to patch an
 * item by id. The per-session plan state (on the push-bus transcript) reflects
 * the set, then the patch.
 */

process.env.AGENT_DECK_TEST = "1";

let mock: MockProviderServer;
let server: AgentDeckServer;
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const cwd = mkdtempSync(path.join(tmpdir(), "pi-plan-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));

function toolResultCount(body: ChatCompletionRequest): number {
  return body.messages.filter((m) => m.role === "tool").length;
}

beforeAll(async () => {
  mock = await startMockProvider({
    toolCall: (_lastUser, body) => {
      const n = toolResultCount(body);
      // First: set a 2-item plan (explicit ids for a deterministic update).
      if (n === 0) {
        return {
          name: "set_session_plan",
          arguments: {
            items: [
              { id: "a", title: "Write the tests" },
              { id: "b", title: "Ship it", status: "in_progress" },
            ],
          },
        };
      }
      // Then: mark item "a" done.
      if (n === 1) {
        return {
          name: "update_session_plan",
          arguments: { updates: [{ id: "a", status: "done" }] },
        };
      }
      return null;
    },
    reply: () => "Plan managed.",
  });
  process.env.AGENT_DECK_PROVIDER_EXTENSIONS = writeMockProviderExtension(mock.baseUrl);
  server = await startServer({ dataDir });
});

afterAll(async () => {
  await server.close();
  await mock.close();
  delete process.env.AGENT_DECK_PROVIDER_EXTENSIONS;
});

describe("session plan: set then update via parent bridge tools", () => {
  it("reflects the set plan and the patched item status", async () => {
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

    await managed.prompt("plan the work");
    await server.receipts.waitFor("idle", session.id);

    // The plan reflects the set (2 items, ids preserved) and the update (a → done).
    const plan = managed.snapshot().state.plan;
    expect(plan).toEqual([
      { id: "a", title: "Write the tests", status: "done" },
      { id: "b", title: "Ship it", status: "in_progress" },
    ]);
  });
});
