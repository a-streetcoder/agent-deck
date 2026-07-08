import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  MOCK_MODEL_ID,
  MOCK_PROVIDER_ID,
  startMockProvider,
  writeMockProviderExtension,
  type MockProviderServer,
} from "@agent-deck/testkit";
import type { SessionMeta } from "@agent-deck/domain";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * Resuming a session that has NO pi session file (a draft that never ran a turn,
 * or an old index entry from before session files existed) must OPEN it — a
 * fresh parent launch with an empty transcript — not 409. Regression for the
 * "session has no pi session file to resume" error hit when clicking an old
 * session in the UI.
 */

process.env.AGENT_DECK_TEST = "1";

let mock: MockProviderServer;
let server: AgentDeckServer;
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const cwd = mkdtempSync(path.join(tmpdir(), "pi-resume-nofile-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));
const SESSION_ID = "old-draft-session";

beforeAll(async () => {
  mock = await startMockProvider({ reply: () => "ok" });
  // The relaunch reads its provider/model/extensions from env defaults (no stored
  // launch plan on this seeded session).
  process.env.AGENT_DECK_PROVIDER_EXTENSIONS = writeMockProviderExtension(mock.baseUrl);
  process.env.AGENT_DECK_DEFAULT_PROVIDER = MOCK_PROVIDER_ID;
  process.env.AGENT_DECK_DEFAULT_MODEL = MOCK_MODEL_ID;
  process.env.AGENT_DECK_PI_ENV = JSON.stringify({
    HOME: tmpHome,
    USERPROFILE: tmpHome,
    PI_SKIP_VERSION_CHECK: "1",
  });

  // Seed the on-disk index with a session that never ran (no piSessionFile).
  const seeded: SessionMeta[] = [{ id: SESSION_ID, cwd, createdAt: new Date(0).toISOString() }];
  writeFileSync(path.join(dataDir, "sessions.json"), JSON.stringify(seeded));

  server = await startServer({ dataDir });
});

afterAll(async () => {
  await server.close();
  await mock.close();
  delete process.env.AGENT_DECK_PROVIDER_EXTENSIONS;
  delete process.env.AGENT_DECK_DEFAULT_PROVIDER;
  delete process.env.AGENT_DECK_DEFAULT_MODEL;
  delete process.env.AGENT_DECK_PI_ENV;
});

describe("resume a session with no pi session file", () => {
  it("opens it as a fresh live session instead of returning 409", async () => {
    const res = await fetch(`http://127.0.0.1:${server.port}/sessions/${SESSION_ID}/resume`, {
      method: "POST",
    });
    expect(res.status).toBe(200);
    const { session } = (await res.json()) as { session: { id: string } };
    expect(session.id).toBe(SESSION_ID);

    // It's now live and promptable (a fresh parent pi launched).
    const managed = server.sessions.get(SESSION_ID);
    expect(managed?.isRunning).toBe(true);
    expect(managed?.snapshot().state.cells).toEqual([]); // empty transcript, no crash
  });
});
