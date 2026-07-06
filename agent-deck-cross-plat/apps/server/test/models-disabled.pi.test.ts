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
 * Model enable/disable (native Runtime → Models "Disabled" curation): a user can
 * hide a model from the picker. The app persists the disabled set and the
 * session's model catalog marks each model's disabled flag.
 */

process.env.AGENT_DECK_TEST = "1";

let mock: MockProviderServer;
let server: AgentDeckServer;
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const cwd = mkdtempSync(path.join(tmpdir(), "pi-models-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));

let sessionId: string;

async function fetchModels(): Promise<Array<{ provider: string; id: string; disabled?: boolean }>> {
  const res = await fetch(`http://127.0.0.1:${server.port}/sessions/${sessionId}/models`);
  const { models } = (await res.json()) as {
    models: Array<{ provider: string; id: string; disabled?: boolean }>;
  };
  return models;
}

async function setDisabled(disabled: boolean): Promise<number> {
  const res = await fetch(`http://127.0.0.1:${server.port}/runtime/models/disabled`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ provider: MOCK_PROVIDER_ID, id: MOCK_MODEL_ID, disabled }),
  });
  return res.status;
}

beforeAll(async () => {
  mock = await startMockProvider({ reply: () => "ok" });
  server = await startServer({ dataDir });
  const res = await fetch(`http://127.0.0.1:${server.port}/sessions`, {
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
  sessionId = ((await res.json()) as { session: { id: string } }).session.id;
});

afterAll(async () => {
  await server.close();
  await mock.close();
});

describe("model enable/disable curation", () => {
  it("marks a model disabled after hiding it, and enabled after showing it again", async () => {
    // The mock model is available and enabled by default.
    const before = (await fetchModels()).find((m) => m.id === MOCK_MODEL_ID);
    expect(before).toBeDefined();
    expect(before!.disabled ?? false).toBe(false);

    // Hide it → the catalog marks it disabled.
    expect(await setDisabled(true)).toBe(200);
    expect((await fetchModels()).find((m) => m.id === MOCK_MODEL_ID)!.disabled).toBe(true);

    // Show it again → back to enabled.
    expect(await setDisabled(false)).toBe(200);
    expect((await fetchModels()).find((m) => m.id === MOCK_MODEL_ID)!.disabled).toBe(false);
  });
});
