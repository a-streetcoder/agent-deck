import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { writeMemory, type MemoryStore } from "@agent-deck/memory";
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
 * Per-turn memory recall via the before_agent_start hook: with a query-RELEVANT
 * memory and an IRRELEVANT one stored, the hook injects the relevant memory's
 * BODY into the turn's system prompt (the launch index carries only titles) —
 * and does NOT inject the irrelevant one. End-to-end against real pi.
 */

process.env.AGENT_DECK_TEST = "1";

let mock: MockProviderServer;
let server: AgentDeckServer;
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const cwd = mkdtempSync(path.join(tmpdir(), "pi-recall-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));

function systemText(request: ChatCompletionRequest): string {
  return request.messages
    .filter((m) => m.role === "developer" || m.role === "system")
    .map((m) => (typeof m.content === "string" ? m.content : JSON.stringify(m.content)))
    .join("\n");
}

beforeAll(async () => {
  // Seed the project's memory store: one relevant to a "postgres migration
  // rollback" query, one about unrelated CSS styling.
  const store: MemoryStore = { baseDir: path.join(dataDir, "memory"), projectPath: cwd };
  writeMemory(store, {
    type: "runbook",
    title: "Postgres migration rollback",
    summary: "postgres database migration rollback procedure steps",
    body: "RECALL_BODY_ALPHA: to roll back a postgres migration, run the down script then re-seed.",
  });
  writeMemory(store, {
    type: "preference",
    title: "Button styling",
    summary: "css tailwind button colors spacing frontend",
    body: "RECALL_BODY_BETA: the primary button uses the accent token with capsule radius.",
  });

  mock = await startMockProvider({ reply: () => "ok" });
  server = await startServer({ dataDir });
});

afterAll(async () => {
  await server.close();
  await mock.close();
});

describe("memory recall: before_agent_start injects query-relevant memory bodies", () => {
  it("surfaces the relevant memory's body and not the irrelevant one", async () => {
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

    await server.sessions
      .get(session.id)!
      .prompt("how do I roll back a postgres database migration?");
    await server.receipts.waitFor("idle", session.id);

    const sys = systemText(mock.requests[mock.requests.length - 1]!);
    // The relevant memory's BODY was recalled into the turn's system prompt.
    expect(sys).toContain("RECALL_BODY_ALPHA");
    // The irrelevant memory's body was NOT.
    expect(sys).not.toContain("RECALL_BODY_BETA");
  });
});
