import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
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
 * Extension DISCOVERY (native PiExtensionDiscoveryService): a user's own pi
 * extension sitting in the standard location (<project>/.pi/extensions) is
 * surfaced by GET /resources/extensions WITHOUT being added by hand, and is
 * injected into the session launch so it actually loads. Proven end-to-end
 * against real pi: a discovered extension's before_agent_start hook stamps a
 * sentinel into the system prompt, which only reaches the model if the extension
 * was loaded — and stops reaching it once the extension is disabled.
 */

process.env.AGENT_DECK_TEST = "1";

const SENTINEL = "DISCOVERED_EXT_SENTINEL_42";

let mock: MockProviderServer;
let server: AgentDeckServer;
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
// The server discovers extensions under the same HOME pi runs with (via
// AGENT_DECK_PI_ENV), so the scan is hermetic — it sees only this test's dirs,
// not the developer's real ~/.pi/agent/extensions.
process.env.AGENT_DECK_PI_ENV = JSON.stringify({ HOME: tmpHome });
const project = mkdtempSync(path.join(tmpdir(), "pi-ext-disc-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));
const extPath = path.join(project, ".pi", "extensions", "sentinel.ts");
const conflictPath = path.join(project, ".pi", "extensions", "rogue-memory.ts");
let projectId: string;

function systemText(request: ChatCompletionRequest): string {
  return request.messages
    .filter((m) => m.role === "developer" || m.role === "system")
    .map((m) => (typeof m.content === "string" ? m.content : JSON.stringify(m.content)))
    .join("\n");
}

async function promptAndReadSystem(): Promise<string> {
  const res = await fetch(`http://127.0.0.1:${server.port}/sessions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      cwd: project,
      projectId,
      provider: MOCK_PROVIDER_ID,
      model: MOCK_MODEL_ID,
      extensions: [writeMockProviderExtension(mock.baseUrl)],
      env: { HOME: tmpHome, USERPROFILE: tmpHome, PI_SKIP_VERSION_CHECK: "1" },
    }),
  });
  expect(res.status).toBe(201);
  const { session } = (await res.json()) as { session: { id: string } };
  const before = mock.requests.length;
  await server.sessions.get(session.id)!.prompt("hello");
  await server.receipts.waitFor("idle", session.id);
  return mock.requests.slice(before).map(systemText).join("\n");
}

beforeAll(async () => {
  mock = await startMockProvider({ reply: () => "ok" });

  // A user extension already living in the project's .pi/extensions — never added
  // through the app. Its before_agent_start hook appends a sentinel to the system
  // prompt, so we can detect whether it actually loaded (no network needed).
  mkdirSync(path.dirname(extPath), { recursive: true });
  writeFileSync(
    extPath,
    `export default function (pi) {
  pi.on("before_agent_start", (event) => ({ systemPrompt: event.systemPrompt + "\\n\\n${SENTINEL}" }));
}
`,
  );
  // A rogue extension that re-registers an app-bridge tool — pi would crash if it
  // were injected, so the app must flag it AND exclude it from the launch.
  writeFileSync(
    conflictPath,
    `export default function (pi) {
  pi.registerTool({ name: "agent_deck_memory_write", description: "rogue", parameters: {} }, () => ({ content: "no" }));
}
`,
  );

  server = await startServer({ dataDir });
  const created = (await (
    await fetch(`http://127.0.0.1:${server.port}/projects`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path: project }),
    })
  ).json()) as { project: { id: string } };
  projectId = created.project.id;
});

afterAll(async () => {
  await server.close();
  await mock.close();
  delete process.env.AGENT_DECK_PI_ENV;
});

describe("extension discovery", () => {
  it("surfaces a project extension via GET /resources/extensions (discovered + project scope)", async () => {
    const res = await fetch(
      `http://127.0.0.1:${server.port}/resources/extensions?projectId=${projectId}`,
    );
    const { extensions } = (await res.json()) as {
      extensions: Array<{
        name: string;
        scope: string;
        source: string;
        disabled: boolean;
        bridgeConflict: string | null;
      }>;
    };
    const sentinel = extensions.find((e) => e.name === "sentinel.ts");
    expect(sentinel).toBeDefined();
    expect(sentinel!.scope).toBe("project");
    expect(sentinel!.source).toBe("discovered");
    expect(sentinel!.disabled).toBe(false);
    expect(sentinel!.bridgeConflict).toBeNull();

    // The rogue extension is discovered too, but flagged as conflicting with the
    // memory bridge (so the UI can warn and it's kept out of the launch).
    const rogue = extensions.find((e) => e.name === "rogue-memory.ts");
    expect(rogue?.bridgeConflict).toBe("agent_deck_memory_write");
  });

  it("injects the discovered extension into a session so its hook actually runs, without the conflicting one crashing pi", async () => {
    // The rogue (bridge-conflicting) extension is present on disk but excluded
    // from the launch, so the session starts and the safe extension's hook runs.
    expect(await promptAndReadSystem()).toContain(SENTINEL);
  });

  it("stops injecting the extension once it is disabled by path", async () => {
    const toggle = await fetch(`http://127.0.0.1:${server.port}/resources/extensions/disabled`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path: extPath, disabled: true }),
    });
    expect(toggle.status).toBe(200);
    expect(await promptAndReadSystem()).not.toContain(SENTINEL);
  });

  it("agentDeckManaged loading mode keeps the user extension off even when enabled", async () => {
    const setMode = (mode: string) =>
      fetch(`http://127.0.0.1:${server.port}/settings`, {
        method: "PATCH",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ extensionLoadingMode: mode }),
      });
    // Re-enable the extension (the previous test disabled it) so the mode — not
    // the disabled flag — is what's under test.
    await fetch(`http://127.0.0.1:${server.port}/resources/extensions/disabled`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path: extPath, disabled: false }),
    });

    // Managed mode → only Agent Deck's bridges load; the enabled user extension
    // stays off, so its hook never runs.
    expect((await setMode("agentDeckManaged")).status).toBe(200);
    expect(await promptAndReadSystem()).not.toContain(SENTINEL);

    // Back to "use my extensions" → the same enabled extension loads again.
    expect((await setMode("useMyExtensions")).status).toBe(200);
    expect(await promptAndReadSystem()).toContain(SENTINEL);
  });
});
