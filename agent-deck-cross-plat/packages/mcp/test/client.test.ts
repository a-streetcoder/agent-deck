import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { afterEach, describe, expect, it } from "vitest";
import { McpClient } from "../src/index.ts";

/**
 * The MCP client wrapper, proven against a real in-process MCP server (linked
 * in-memory transport — no subprocess). This is the same client the server uses
 * to proxy a configured MCP server's tools onto the bridge.
 */

let client: McpClient | undefined;

afterEach(async () => {
  await client?.close();
  client = undefined;
});

async function connectToMockServer(): Promise<McpClient> {
  const server = new McpServer({ name: "mock-mcp", version: "0.0.1" });
  server.tool("echo", "Echo a message back", { message: z.string() }, async ({ message }) => ({
    content: [{ type: "text", text: `mcp echo: ${message}` }],
  }));
  server.tool("boom", "Always fails", {}, async () => ({
    content: [{ type: "text", text: "kaboom" }],
    isError: true,
  }));
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  await server.connect(serverTransport);
  return await McpClient.connect(clientTransport);
}

describe("McpClient", () => {
  it("lists an MCP server's tools with their input schemas", async () => {
    client = await connectToMockServer();
    const tools = await client.listTools();
    const echo = tools.find((t) => t.name === "echo");
    expect(echo).toBeDefined();
    expect(echo!.description).toBe("Echo a message back");
    expect(echo!.inputSchema).toMatchObject({ type: "object" });
    expect(
      (echo!.inputSchema as { properties: Record<string, unknown> }).properties,
    ).toHaveProperty("message");
  });

  it("forwards a tool call and flattens the text result", async () => {
    client = await connectToMockServer();
    const result = await client.callTool("echo", { message: "hi" });
    expect(result).toEqual({ content: "mcp echo: hi", isError: false });
  });

  it("surfaces an MCP tool error", async () => {
    client = await connectToMockServer();
    const result = await client.callTool("boom", {});
    expect(result.isError).toBe(true);
    expect(result.content).toContain("kaboom");
  });
});
