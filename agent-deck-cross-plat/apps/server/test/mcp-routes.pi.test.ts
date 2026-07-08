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
 * MCP config routes (the visible half's backend), end-to-end against real pi:
 * POST /mcp adds a stdio server (writing mcp.json + connecting it), GET /mcp
 * reports it connected with its tools, a session can call the tool, and
 * DELETE /mcp/:id removes it and unregisters the tool.
 */

const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
process.env.AGENT_DECK_TEST = "1";
// Hermetic resource home: mcp.json writes go under this tmp home, not ~/.pi.
process.env.AGENT_DECK_PI_ENV = JSON.stringify({ HOME: tmpHome });

let mock: MockProviderServer;
let server: AgentDeckServer;
const cwd = mkdtempSync(path.join(tmpdir(), "pi-mcp-routes-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));

async function api(method: string, url: string, body?: unknown): Promise<Response> {
  return await fetch(`http://127.0.0.1:${server.port}${url}`, {
    method,
    headers: body === undefined ? {} : { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

beforeAll(async () => {
  mock = await startMockProvider({
    toolCall: (_lastUser, body) => {
      const hasToolResult = body.messages.some((m) => m.role === "tool");
      return hasToolResult
        ? null
        : { name: "mcp__mock__echo", arguments: { message: "via routes" } };
    },
    reply: () => "answered.",
  });
  server = await startServer({ dataDir });
});

afterAll(async () => {
  await server.close();
  await mock.close();
  delete process.env.AGENT_DECK_PI_ENV;
});

describe("mcp config routes", () => {
  it("adds a server via POST /mcp and lists it connected with its tools", async () => {
    const launch = mockMcpServerLaunch("mock");
    const res = await api("POST", "/mcp", {
      name: "mock",
      command: launch.command,
      args: launch.args,
    });
    expect(res.status).toBe(201);
    const { server: status } = (await res.json()) as {
      server: { id: string; connected: boolean; toolNames: string[] };
    };
    expect(status.connected).toBe(true);
    expect(status.toolNames).toContain("mcp__mock__echo");

    const list = (await (await api("GET", "/mcp")).json()) as {
      servers: Array<{ id: string; connected: boolean; toolNames: string[] }>;
    };
    const mockServer = list.servers.find((s) => s.id === "mock");
    expect(mockServer?.connected).toBe(true);
    expect(mockServer?.toolNames).toContain("mcp__mock__echo");
  });

  it("lets a real pi session call the added MCP tool", async () => {
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
    const { session } = (await response.json()) as { session: { id: string } };
    await server.sessions.get(session.id)!.prompt("use the mcp tool");
    await server.receipts.waitFor("idle", session.id);

    const followUp = mock.requests[mock.requests.length - 1]!;
    const toolText = JSON.stringify(followUp.messages.filter((m) => m.role === "tool"));
    expect(toolText).toContain("mcp stdio echo: via routes");
  });

  it("removes the server via DELETE and unregisters its tool", async () => {
    expect((await api("DELETE", "/mcp/mock")).status).toBe(200);
    const list = (await (await api("GET", "/mcp")).json()) as { servers: Array<{ id: string }> };
    expect(list.servers.some((s) => s.id === "mock")).toBe(false);
    expect(server.bridge.specs().some((s) => s.name === "mcp__mock__echo")).toBe(false);
    // Deleting an unknown server 404s.
    expect((await api("DELETE", "/mcp/mock")).status).toBe(404);
  });
});

describe("mcp oauth routes", () => {
  const HTTP_ID = "authsrv";

  it("reports per-server auth state and guards the login/callback/logout routes", async () => {
    // Add an http server. Its connect fails against the dead url — fine: the
    // config is stored, so httpUrlFor resolves and the OAuth routes are reachable
    // and its OAuth provider (unauthenticated) exists.
    const add = await api("POST", "/mcp", { name: HTTP_ID, url: "http://127.0.0.1:1/sse" });
    expect(add.status).toBe(201);

    // GET /mcp augments each server with its auth state — http is unauthenticated.
    const list = (await (await api("GET", "/mcp")).json()) as {
      servers: Array<{ id: string; transport: string; auth: { status: string } }>;
    };
    const httpServer = list.servers.find((s) => s.id === HTTP_ID);
    expect(httpServer?.transport).toBe("http");
    expect(httpServer?.auth.status).toBe("unauthenticated");

    // Callback with no code → 400 (schema). With a code but a state never minted →
    // 400 (CSRF guard rejects the mismatch).
    expect((await api("POST", `/mcp/${HTTP_ID}/login/callback`, {})).status).toBe(400);
    expect(
      (await api("POST", `/mcp/${HTTP_ID}/login/callback`, { code: "x", state: "nope" })).status,
    ).toBe(400);

    // login / logout on an unknown server → 404.
    expect((await api("POST", "/mcp/ghost/login", {})).status).toBe(404);
    expect((await api("POST", "/mcp/ghost/logout", {})).status).toBe(404);

    await api("DELETE", `/mcp/${HTTP_ID}`);
  });
});
