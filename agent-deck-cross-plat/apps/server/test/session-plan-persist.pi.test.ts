import { mkdtempSync, readFileSync } from "node:fs";
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
 * Session plan PERSISTENCE across resume: a set plan is persisted onto the
 * session meta (to the on-disk index) and, after the session ends and is
 * resumed (relaunched + rebuilt from pi history), restored into the resumed
 * transcript — the plan is app state, not part of pi's session file.
 */

process.env.AGENT_DECK_TEST = "1";

let mock: MockProviderServer;
let server: AgentDeckServer;
let mockExt: string;
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const cwd = mkdtempSync(path.join(tmpdir(), "pi-plan-persist-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));
const env = { HOME: tmpHome, USERPROFILE: tmpHome, PI_SKIP_VERSION_CHECK: "1" };
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

const PLAN = [
  { id: "a", title: "Write the tests", status: "todo" as const },
  { id: "b", title: "Ship it", status: "in_progress" as const },
];

beforeAll(async () => {
  mock = await startMockProvider({ reply: () => "ok" });
  mockExt = writeMockProviderExtension(mock.baseUrl);
  server = await startServer({ dataDir });
});

afterAll(async () => {
  await server.close();
  await mock.close();
});

describe("session plan persistence: survives ending + resume", () => {
  it("persists the plan to the index and restores it on resume", async () => {
    const res = await fetch(`http://127.0.0.1:${server.port}/sessions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        cwd,
        provider: MOCK_PROVIDER_ID,
        model: MOCK_MODEL_ID,
        extensions: [mockExt],
        env,
      }),
    });
    const { session } = (await res.json()) as { session: { id: string } };
    const managed = server.sessions.get(session.id)!;

    // A turn so pi captures the resume handle (session file).
    await managed.prompt("start the work");
    await server.receipts.waitFor("idle", session.id);
    for (let i = 0; i < 100 && !managed.meta.piSessionFile; i++) await sleep(50);
    expect(managed.meta.piSessionFile).toBeTruthy();

    // Set the plan; it must be mirrored onto the meta and persisted to disk.
    managed.setPlan(PLAN);
    const persisted = JSON.parse(
      readFileSync(path.join(dataDir, "sessions.json"), "utf8"),
    ) as SessionMeta[];
    expect(persisted.find((m) => m.id === session.id)?.plan).toEqual(PLAN);

    // End the session and resume it (relaunch + rebuild from pi history).
    const meta = { ...managed.meta };
    await managed.stop();
    await sleep(100);
    const resumed = await server.sessions.resume(
      meta,
      {
        kind: "parent",
        resumeSessionPath: meta.piSessionFile,
        provider: MOCK_PROVIDER_ID,
        model: MOCK_MODEL_ID,
        extensions: [mockExt],
      },
      env,
    );

    // The transcript was rebuilt from pi (user cell) AND the plan restored.
    const state = resumed.snapshot().state;
    expect(state.cells.some((c) => c.kind === "user")).toBe(true);
    expect(state.plan).toEqual(PLAN);
  });
});
