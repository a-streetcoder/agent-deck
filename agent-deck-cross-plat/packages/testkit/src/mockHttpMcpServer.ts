import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";

export interface MockHttpMcpServer {
  /** The Streamable HTTP endpoint to configure as an http MCP server. */
  url: string;
  close(): Promise<void>;
}

/**
 * A tiny Streamable HTTP MCP server for tests: one `echo` tool, served over a
 * loopback Node http server in stateless JSON-response mode (no session ids —
 * one shared transport handles every request). Lets a test exercise the full
 * http MCP path (connect → listTools → forward) the way the stdio fixture does
 * for stdio. Start it, point AGENT_DECK_MCP_SERVERS at `{ id, url }`, close after.
 */
export async function startMockHttpMcpServer(): Promise<MockHttpMcpServer> {
  const mcp = new McpServer({ name: "mock-mcp-http", version: "0.0.1" });
  mcp.tool("echo", "Echo a message back", { message: z.string() }, ({ message }) => ({
    content: [{ type: "text", text: `mcp http echo: ${message}` }],
  }));
  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: undefined,
    enableJsonResponse: true,
  });
  await mcp.connect(transport);

  const http: Server = createServer((req, res) => {
    // Only serve the advertised endpoint — so a client posting to the wrong path
    // fails loudly instead of the test silently passing on a routing regression.
    if ((req.url ?? "").split("?")[0] !== "/mcp") {
      res.statusCode = 404;
      res.end();
      return;
    }
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      void transport.handleRequest(req, res, body ? JSON.parse(body) : undefined);
    });
  });
  await new Promise<void>((resolve) => http.listen(0, "127.0.0.1", resolve));
  const { port } = http.address() as AddressInfo;

  return {
    url: `http://127.0.0.1:${port}/mcp`,
    close: () =>
      new Promise<void>((resolve) => {
        void transport.close();
        http.close(() => resolve());
      }),
  };
}
