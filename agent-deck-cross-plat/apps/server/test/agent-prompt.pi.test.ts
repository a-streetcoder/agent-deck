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
 * Agent-backed sessions pass the (usually multi-line) agent body as a
 * --system-prompt value. On Windows pi runs via a pi.cmd shim through cmd.exe,
 * which truncates a multi-line argument at the first newline — so the body must
 * be routed through a temp file (pi reads a path value as a file). This proves
 * the WHOLE multi-line body reaches the model, including lines after the first.
 */

process.env.AGENT_DECK_TEST = "1";

const AGENT_BODY = [
  "You are a specialist agent.",
  "Line two: follow the house rules.",
  "AGENT_LINE3_SENTINEL: this line comes after a newline.",
  "Final line of the agent body.",
].join("\n");

let mock: MockProviderServer;
let server: AgentDeckServer;
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const cwd = mkdtempSync(path.join(tmpdir(), "pi-agent-prompt-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));

function systemText(request: ChatCompletionRequest): string {
  return request.messages
    .filter((m) => m.role === "developer" || m.role === "system")
    .map((m) => (typeof m.content === "string" ? m.content : JSON.stringify(m.content)))
    .join("\n");
}

beforeAll(async () => {
  mock = await startMockProvider({ reply: () => "ok" });
  server = await startServer({ dataDir });
});

afterAll(async () => {
  await server.close();
  await mock.close();
});

describe("agent session: multi-line system prompt reaches the model whole", () => {
  it("delivers every line of the agent body (routed through a temp file)", async () => {
    const session = server.sessions.create({
      cwd,
      plan: {
        kind: "agent",
        systemPrompt: { mode: "replace", text: AGENT_BODY },
        provider: MOCK_PROVIDER_ID,
        model: MOCK_MODEL_ID,
        extensions: [writeMockProviderExtension(mock.baseUrl)],
      },
      env: { HOME: tmpHome, USERPROFILE: tmpHome, PI_SKIP_VERSION_CHECK: "1" },
    });

    await session.prompt("hello");
    await server.receipts.waitFor("idle", session.meta.id);

    const system = systemText(mock.requests[0]!);
    // A replace-mode agent body becomes the system prompt; every line — not just
    // the first — must be present (the post-newline line is the Windows tell).
    expect(system).toContain("You are a specialist agent.");
    expect(system).toContain("AGENT_LINE3_SENTINEL: this line comes after a newline.");
    expect(system).toContain("Final line of the agent body.");
  });
});
