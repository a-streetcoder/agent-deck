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
 * Onboarding preferences applied at session launch: a user's defaultModel /
 * defaultThinking seed a plain parent session's launch plan, and autoTitle=false
 * suppresses the title-helper launch. Also guards the PATCH /settings contract
 * (invalid thinking → 400; a preference patch never clobbers defaultSkills).
 */

process.env.AGENT_DECK_TEST = "1";

let mock: MockProviderServer;
let server: AgentDeckServer;
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const cwd = mkdtempSync(path.join(tmpdir(), "pi-prefs-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));

async function patchSettings(body: unknown): Promise<Response> {
  return fetch(`http://127.0.0.1:${server.port}/settings`, {
    method: "PATCH",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function createSession(opts: { withProvider?: boolean } = {}): Promise<string> {
  const body: Record<string, unknown> = {
    cwd,
    // No model/thinking in the request — they must come from the settings.
    extensions: [process.env.AGENT_DECK_PROVIDER_EXTENSIONS],
    env: { HOME: tmpHome, USERPROFILE: tmpHome, PI_SKIP_VERSION_CHECK: "1" },
  };
  // Omit the provider to prove it's derived from the provider-qualified default.
  if (opts.withProvider !== false) body.provider = MOCK_PROVIDER_ID;
  const res = await fetch(`http://127.0.0.1:${server.port}/sessions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  expect(res.status).toBe(201);
  const { session } = (await res.json()) as { session: { id: string } };
  return session.id;
}

beforeAll(async () => {
  mock = await startMockProvider({ reply: () => "ok" });
  process.env.AGENT_DECK_PROVIDER_EXTENSIONS = writeMockProviderExtension(mock.baseUrl);
  server = await startServer({ dataDir });
});

afterAll(async () => {
  await server.close();
  await mock.close();
  delete process.env.AGENT_DECK_PROVIDER_EXTENSIONS;
});

describe("onboarding preferences at session launch", () => {
  it("rejects an invalid thinking level and never clobbers defaultSkills", async () => {
    // A patch that sets one preference must leave the skills array intact.
    expect((await patchSettings({ defaultSkills: ["keeper"] })).status).toBe(200);
    expect((await patchSettings({ autoTitle: false })).status).toBe(200);
    const bad = await patchSettings({ defaultThinking: "bogus" });
    expect(bad.status).toBe(400);

    const settings = (await (await fetch(`http://127.0.0.1:${server.port}/settings`)).json()) as {
      settings: { defaultSkills: string[]; autoTitle: boolean };
    };
    expect(settings.settings.defaultSkills).toEqual(["keeper"]);
    expect(settings.settings.autoTitle).toBe(false);
  });

  it("seeds a parent session's provider + model + thinking from the settings", async () => {
    // The default model is provider-qualified, so the launch derives BOTH the
    // provider and the model from it even when the request omits the provider.
    expect(
      (
        await patchSettings({
          defaultModel: `${MOCK_PROVIDER_ID}:${MOCK_MODEL_ID}`,
          defaultThinking: "low",
        })
      ).status,
    ).toBe(200);

    const id = await createSession({ withProvider: false });
    // launchPlan is persisted structurally (SessionMeta keeps it opaque); read
    // the parent-plan fields we set.
    const plan = server.sessions.get(id)!.meta.launchPlan as
      | { kind?: string; provider?: string; model?: string; thinking?: string }
      | undefined;
    expect(plan?.kind).toBe("parent");
    expect(plan?.provider).toBe(MOCK_PROVIDER_ID);
    expect(plan?.model).toBe(MOCK_MODEL_ID);
    expect(plan?.thinking).toBe("low");

    // And pi actually launches + responds with that model/thinking applied.
    const managed = server.sessions.get(id)!;
    await managed.prompt("hello");
    await server.receipts.waitFor("idle", id);
    expect(managed.snapshot().state.cells.some((c) => c.kind === "assistant")).toBe(true);
  });

  it("suppresses the title helper when autoTitle is off", async () => {
    expect((await patchSettings({ autoTitle: false })).status).toBe(200);
    const id = await createSession();
    const managed = server.sessions.get(id)!;
    await managed.prompt("give me a title-worthy first message");
    await server.receipts.waitFor("idle", id);

    // No title receipt ever fires (the helper is never launched); the timeout is
    // the ONLY way this resolves, so it rejects.
    await expect(server.receipts.waitFor("title", id, 5000)).rejects.toThrow();
    expect(managed.meta.title).toBeUndefined();
  });
});
