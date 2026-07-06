import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

/**
 * A tiny stdio MCP server for tests: one `echo` tool. Plain .mjs so Node runs it
 * as a subprocess directly — no build step and no --experimental-strip-types
 * flag (which not every Node 22 minor supports), so it works on every CI runner.
 * The server-side wiring test spawns this so the FULL production MCP path
 * (spawn → connect → listTools → forward) is exercised end-to-end.
 */

const server = new McpServer({ name: "mock-mcp-stdio", version: "0.0.1" });
server.tool("echo", "Echo a message back", { message: z.string() }, ({ message }) => ({
  content: [{ type: "text", text: `mcp stdio echo: ${message}` }],
}));

await server.connect(new StdioServerTransport());
