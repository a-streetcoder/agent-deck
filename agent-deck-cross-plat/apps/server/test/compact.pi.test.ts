import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
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
 * Manual compaction (native "Compact context"): the server routes a `compact`
 * command to pi, which summarizes older history and emits `compaction_end`. The
 * ingest already maps that to a contextRevision bump (the context-usage chip
 * re-reads stats on it), so a successful manual compaction is observable as a
 * contextRevision increment on the parent transcript.
 */

process.env.AGENT_DECK_TEST = "1";

let mock: MockProviderServer;
let server: AgentDeckServer;
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const cwd = mkdtempSync(path.join(tmpdir(), "pi-compact-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));

beforeAll(async () => {
  mock = await startMockProvider({ reply: () => "Acknowledged." });
  process.env.AGENT_DECK_PROVIDER_EXTENSIONS = writeMockProviderExtension(mock.baseUrl);
  server = await startServer({ dataDir });
});

afterAll(async () => {
  await server.close();
  await mock.close();
  delete process.env.AGENT_DECK_PROVIDER_EXTENSIONS;
});

describe("manual compaction (native Compact context)", () => {
  it("compacting the session bumps the transcript's contextRevision", async () => {
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

    // pi only compacts history BEYOND its recent-token window (keepRecentTokens
    // = 20000), so build several large-message turns to exceed it — otherwise pi
    // rejects with "Nothing to compact (session too small)". Serialize on the
    // assistant-cell count (the one-shot receipt bus can't gate a loop).
    const assistantCount = (): number =>
      managed.snapshot().state.cells.filter((c) => c.kind === "assistant").length;
    for (let i = 0; i < 5; i += 1) {
      const done = assistantCount();
      await managed.prompt(`turn ${i}: ${`word `.repeat(8000)}`);
      await expect.poll(assistantCount, { timeout: 20_000 }).toBeGreaterThan(done);
    }
    const before = managed.snapshot().state.contextRevision;

    // Manual compaction → pi emits compaction_end, which the ingest turns into a
    // contextRevision bump.
    await managed.compact();
    await expect
      .poll(() => managed.snapshot().state.contextRevision, { timeout: 15_000 })
      .toBeGreaterThan(before);
  });
});
