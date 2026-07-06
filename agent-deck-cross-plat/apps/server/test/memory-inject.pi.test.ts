import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
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
 * Launch-time memory injection (memory.md §Memory Policy Injection): a parent
 * session's system prompt carries the project memory index + policy, injected
 * via --append-system-prompt. And because any explicit append suppresses pi's
 * automatic APPEND_SYSTEM.md discovery, the resolved project APPEND_SYSTEM.md is
 * re-added ahead of it — so it is still honored (agent-deck-system-prompt-logic.md).
 */

process.env.AGENT_DECK_TEST = "1";

const APPEND_SENTINEL = "PROJECT_APPEND_SENTINEL_XYZ: obey the house style.";

let mock: MockProviderServer;
let server: AgentDeckServer;

const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const cwd = mkdtempSync(path.join(tmpdir(), "pi-mem-inject-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));

function systemText(request: ChatCompletionRequest): string {
  // pi's OpenAI-completions provider carries the system prompt as the
  // "developer" role (newer OpenAI convention); accept "system" too.
  return request.messages
    .filter((m) => m.role === "developer" || m.role === "system")
    .map((m) => (typeof m.content === "string" ? m.content : JSON.stringify(m.content)))
    .join("\n");
}

const GLOBAL_SENTINEL = "GLOBAL_APPEND_SENTINEL_QWE: global house rules.";
const cwdNoProjectAppend = mkdtempSync(path.join(tmpdir(), "pi-mem-inject-global-"));

beforeAll(async () => {
  // A project APPEND_SYSTEM.md pi would auto-discover.
  mkdirSync(path.join(cwd, ".pi"), { recursive: true });
  writeFileSync(path.join(cwd, ".pi", "APPEND_SYSTEM.md"), APPEND_SENTINEL);
  // A GLOBAL APPEND_SYSTEM.md under the session's HOME override — must be found
  // via the launch HOME (not the server process home) when a project has none.
  mkdirSync(path.join(tmpHome, ".pi", "agent"), { recursive: true });
  writeFileSync(path.join(tmpHome, ".pi", "agent", "APPEND_SYSTEM.md"), GLOBAL_SENTINEL);

  // Pre-seed a memory so the injected index has a line at launch.
  const store: MemoryStore = { baseDir: path.join(dataDir, "memory"), projectPath: cwd };
  const seeded = writeMemory(store, {
    type: "decision",
    title: "Package manager choice",
    summary: "The monorepo uses pnpm workspaces",
    body: "We use pnpm, not npm.",
  });
  if (!seeded.ok) throw new Error("failed to seed memory");

  mock = await startMockProvider({ reply: () => "ok" });
  server = await startServer({ dataDir });
});

afterAll(async () => {
  await server.close();
  await mock.close();
});

describe("memory: launch-time index injection + APPEND_SYSTEM.md preservation", () => {
  it("injects the memory index and still honors the project APPEND_SYSTEM.md", async () => {
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

    await server.sessions.get(session.id)!.prompt("hello");
    await server.receipts.waitFor("idle", session.id);

    const system = systemText(mock.requests[0]!);
    // The memory policy + the seeded memory's index line are present.
    expect(system).toContain("Agent Deck project memory");
    expect(system).toContain("Package manager choice");
    // The project APPEND_SYSTEM.md content survived (not suppressed by our append).
    expect(system).toContain(APPEND_SENTINEL);
  });

  it("preserves the GLOBAL APPEND_SYSTEM.md resolved against the session's HOME", async () => {
    const response = await fetch(`http://127.0.0.1:${server.port}/sessions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        cwd: cwdNoProjectAppend, // no project .pi/APPEND_SYSTEM.md → global applies
        provider: MOCK_PROVIDER_ID,
        model: MOCK_MODEL_ID,
        extensions: [writeMockProviderExtension(mock.baseUrl)],
        env: { HOME: tmpHome, USERPROFILE: tmpHome, PI_SKIP_VERSION_CHECK: "1" },
      }),
    });
    expect(response.status).toBe(201);
    const { session } = (await response.json()) as { session: { id: string } };

    await server.sessions.get(session.id)!.prompt("hi");
    await server.receipts.waitFor("idle", session.id);

    const system = systemText(mock.requests[mock.requests.length - 1]!);
    expect(system).toContain("Agent Deck project memory");
    // The global APPEND_SYSTEM.md (under the launch HOME) is honored.
    expect(system).toContain(GLOBAL_SENTINEL);
  });
});
