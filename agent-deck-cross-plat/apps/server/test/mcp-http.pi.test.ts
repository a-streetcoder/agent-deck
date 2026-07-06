import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  MOCK_MODEL_ID,
  MOCK_PROVIDER_ID,
  startMockHttpMcpServer,
  startMockProvider,
  writeMockProviderExtension,
  type MockHttpMcpServer,
  type MockProviderServer,
} from "@agent-deck/testkit";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * HTTP (Streamable HTTP) MCP through the bridge, end-to-end against real pi: a
 * configured http MCP server's `echo` tool is registered as mcp__mockhttp__echo;
 * a real pi session calls it, the call reaches /bridge, the server forwards it
 * over the Streamable HTTP MCP client to the remote server, and the result flows
 * back to the model. Mirrors the stdio MCP test with the http transport.
 */

process.env.AGENT_DECK_TEST = "1";

let mock: MockProviderServer;
let server: AgentDeckServer;
let mcpHttp: MockHttpMcpServer;

const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const cwd = mkdtempSync(path.join(tmpdir(), "pi-mcp-http-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));

beforeAll(async () => {
  mock = await startMockProvider({
    toolCall: (_lastUser, body) => {
      const hasToolResult = body.messages.some((m) => m.role === "tool");
      return hasToolResult
        ? null
        : { name: "mcp__mockhttp__echo", arguments: { message: "over http" } };
    },
    reply: () => "The MCP tool answered.",
  });
  // The http MCP server must be listening BEFORE startServer reads the env config.
  mcpHttp = await startMockHttpMcpServer();
  process.env.AGENT_DECK_MCP_SERVERS = JSON.stringify([{ id: "mockhttp", url: mcpHttp.url }]);
  server = await startServer({ dataDir });
});

afterAll(async () => {
  await server.close();
  await mock.close();
  await mcpHttp.close();
  delete process.env.AGENT_DECK_MCP_SERVERS;
});

describe("mcp http: a configured Streamable HTTP server's tool is callable through the bridge", () => {
  it("registers the http MCP tool and forwards a real pi call to the remote server", async () => {
    expect(server.bridge.specs().some((s) => s.name === "mcp__mockhttp__echo")).toBe(true);
    // GET /mcp reports the http transport, connected, with the echo tool.
    const mcpList = (await (await fetch(`http://127.0.0.1:${server.port}/mcp`)).json()) as {
      servers: Array<{ id: string; transport: string; connected: boolean; toolNames: string[] }>;
    };
    const entry = mcpList.servers.find((s) => s.id === "mockhttp");
    expect(entry?.transport).toBe("http");
    expect(entry?.connected).toBe(true);
    expect(entry?.toolNames).toContain("mcp__mockhttp__echo");

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

    const followUp = mock.requests[mock.requests.length - 1]!;
    const toolText = JSON.stringify(followUp.messages.filter((m) => m.role === "tool"));
    expect(toolText).toContain("mcp http echo: over http");
  });
});
