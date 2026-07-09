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
 * Session content search (native Sessions search 18.1 "by title or content"):
 * GET /sessions/search?q scans each session's pi file — the canonical transcript
 * — so a query matches a word from the conversation, not just the title.
 */

process.env.AGENT_DECK_TEST = "1";

let mock: MockProviderServer;
let server: AgentDeckServer;
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const cwd = mkdtempSync(path.join(tmpdir(), "pi-search-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));

async function search(q: string): Promise<string[]> {
  const res = await fetch(
    `http://127.0.0.1:${server.port}/sessions/search?q=${encodeURIComponent(q)}`,
  );
  const { ids } = (await res.json()) as { ids: string[] };
  return ids;
}

beforeAll(async () => {
  mock = await startMockProvider({ reply: () => "acknowledged" });
  process.env.AGENT_DECK_PROVIDER_EXTENSIONS = writeMockProviderExtension(mock.baseUrl);
  server = await startServer({ dataDir });
});

afterAll(async () => {
  await server.close();
  await mock.close();
  delete process.env.AGENT_DECK_PROVIDER_EXTENSIONS;
});

describe("session content search", () => {
  it("matches a word from the conversation, not just the title", async () => {
    const res = await fetch(`http://127.0.0.1:${server.port}/sessions`, {
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
    expect(res.status).toBe(201);
    const { session } = (await res.json()) as { session: { id: string } };

    const managed = server.sessions.get(session.id)!;
    await managed.prompt("please note the codeword zorptastic for later");
    await server.receipts.waitFor("idle", session.id);

    // The pi session file is captured asynchronously after idle; poll the search
    // until a word from the conversation matches (case-insensitive).
    await expect
      .poll(async () => (await search("ZORPTASTIC")).includes(session.id), { timeout: 5000 })
      .toBe(true);

    // An absent word doesn't match; an empty query returns nothing.
    expect(await search("nonexistent-term-xyzzy")).not.toContain(session.id);
    expect(await search("   ")).toEqual([]);
  });
});
