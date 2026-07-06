import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  MOCK_MODEL_ID,
  MOCK_PROVIDER_ID,
  mockMcpServerLaunch,
  startMockProvider,
  writeMockProviderExtension,
  type ChatCompletionRequest,
  type MockProviderServer,
} from "@agent-deck/testkit";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * Per-session MCP scoping (native explicit-assignment model): an agent that
 * DECLARES mcpServers exposes only those servers' MCP tools to its sessions; an
 * agent that declares none (opt-in default) gets no MCP tools; a PLAIN session
 * (no agent) is unrestricted. End-to-end against real pi with a configured stdio
 * MCP server "mock" (tool mcp__mock__echo).
 */

const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const cwd = mkdtempSync(path.join(tmpdir(), "pi-per-agent-mcp-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));

process.env.AGENT_DECK_TEST = "1";
process.env.AGENT_DECK_PI_ENV = JSON.stringify({ HOME: tmpHome });
process.env.AGENT_DECK_MCP_SERVERS = JSON.stringify([mockMcpServerLaunch("mock")]);

let mock: MockProviderServer;
let server: AgentDeckServer;
let mockExt: string;
const env = { HOME: tmpHome, USERPROFILE: tmpHome, PI_SKIP_VERSION_CHECK: "1" };

function writeGlobalAgent(name: string, frontmatter: string, body: string): void {
  const dir = path.join(tmpHome, ".pi", "agent", "agents");
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    path.join(dir, `${name}.md`),
    `---\nname: ${name}\n${frontmatter}\n---\n\n${body}\n`,
  );
}

function toolResults(reqs: ChatCompletionRequest[]): string {
  return JSON.stringify(reqs.flatMap((r) => r.messages.filter((m) => m.role === "tool")));
}

async function runSession(agentName?: string): Promise<ChatCompletionRequest[]> {
  const start = mock.requests.length;
  const res = await fetch(`http://127.0.0.1:${server.port}/sessions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      cwd,
      agentName,
      provider: MOCK_PROVIDER_ID,
      model: MOCK_MODEL_ID,
      extensions: [mockExt],
      env,
    }),
  });
  expect(res.status).toBe(201);
  const { session } = (await res.json()) as { session: { id: string } };
  await server.sessions.get(session.id)!.prompt("use the mcp echo tool");
  await server.receipts.waitFor("idle", session.id);
  return mock.requests.slice(start);
}

beforeAll(async () => {
  writeGlobalAgent("mcp-yes", "mcpServers: mock", "You use the MCP echo tool.");
  // Declares no mcpServers at all → opt-in default is no MCP tools.
  writeGlobalAgent("mcp-none", "description: plain", "You do not use MCP.");
  mock = await startMockProvider({
    toolCall: (_lastUser, body) =>
      body.messages.some((m) => m.role === "tool")
        ? null
        : { name: "mcp__mock__echo", arguments: { message: "scoped" } },
    reply: () => "done",
  });
  mockExt = writeMockProviderExtension(mock.baseUrl);
  server = await startServer({ dataDir });
});

afterAll(async () => {
  await server.close();
  await mock.close();
  delete process.env.AGENT_DECK_PI_ENV;
  delete process.env.AGENT_DECK_MCP_SERVERS;
});

describe("per-session MCP scoping by an agent's declared mcpServers", () => {
  it("exposes the declared server's MCP tool to its agent session", async () => {
    // The server has the MCP tool registered globally.
    expect(server.bridge.specs().some((s) => s.name === "mcp__mock__echo")).toBe(true);
    const reqs = await runSession("mcp-yes");
    // The agent declared mock, so mcp__mock__echo ran and its result came back.
    expect(toolResults(reqs)).toContain("mcp stdio echo: scoped");
  });

  it("hides all MCP tools from an agent that declares none (opt-in)", async () => {
    const reqs = await runSession("mcp-none");
    // mcp__mock__echo was NOT exposed to this session, so it never produced output.
    expect(toolResults(reqs)).not.toContain("mcp stdio echo");
  });

  it("leaves a plain session (no agent) unrestricted", async () => {
    const reqs = await runSession();
    // No agent → all configured MCP servers, so the echo tool is available.
    expect(toolResults(reqs)).toContain("mcp stdio echo: scoped");
  });
});
