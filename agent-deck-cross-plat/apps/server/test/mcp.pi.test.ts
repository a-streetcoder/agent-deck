import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  MOCK_MODEL_ID,
  MOCK_PROVIDER_ID,
  mockMcpServerLaunch,
  startMockProvider,
  writeMockProviderExtension,
  type MockProviderServer,
} from "@agent-deck/testkit";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * MCP through the bridge, end-to-end against real pi (permanent CI guard): a
 * configured stdio MCP server's `echo` tool is registered on the bridge as
 * mcp__mock__echo; a real pi session calls it, the call reaches our /bridge
 * route, the server forwards it to the MCP client → the MCP server subprocess,
 * and the result flows back to the model. Exercises the full production path.
 */

process.env.AGENT_DECK_TEST = "1";
process.env.AGENT_DECK_MCP_SERVERS = JSON.stringify([mockMcpServerLaunch("mock")]);

let mock: MockProviderServer;
let server: AgentDeckServer;

const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const cwd = mkdtempSync(path.join(tmpdir(), "pi-mcp-it-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));

beforeAll(async () => {
  mock = await startMockProvider({
    toolCall: (_lastUser, body) => {
      const hasToolResult = body.messages.some((m) => m.role === "tool");
      return hasToolResult ? null : { name: "mcp__mock__echo", arguments: { message: "over mcp" } };
    },
    reply: () => "The MCP tool answered.",
  });
  server = await startServer({ dataDir });
});

afterAll(async () => {
  await server.close();
  await mock.close();
  delete process.env.AGENT_DECK_MCP_SERVERS;
});

describe("mcp: a configured server's tool is callable through the bridge", () => {
  it("registers the MCP tool and forwards a real pi call to the MCP server", async () => {
    // The MCP tool is advertised on the bridge with the mcp__<server>__<tool> name.
    expect(server.bridge.specs().some((s) => s.name === "mcp__mock__echo")).toBe(true);

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

    await server.sessions.get(session.id)!.prompt("use the mcp echo tool");
    await server.receipts.waitFor("idle", session.id);

    // The MCP server's result flowed back to the model (a role:"tool" follow-up).
    const followUp = mock.requests[mock.requests.length - 1]!;
    const toolText = JSON.stringify(followUp.messages.filter((m) => m.role === "tool"));
    expect(toolText).toContain("mcp stdio echo: over mcp");
  });
});
