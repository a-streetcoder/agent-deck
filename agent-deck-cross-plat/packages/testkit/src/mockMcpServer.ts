import { fileURLToPath } from "node:url";

/**
 * Launch config for the tiny stdio MCP server fixture (mockMcpServer.mjs) — a
 * plain-JS entry so Node runs it directly (no --experimental-strip-types).
 * Returned as an AGENT_DECK_MCP_SERVERS-shaped config so a test can point the
 * server at it.
 */
export function mockMcpServerLaunch(id = "mock"): {
  id: string;
  command: string;
  args: string[];
} {
  const modulePath = fileURLToPath(new URL("./mockMcpServer.mjs", import.meta.url));
  return { id, command: process.execPath, args: [modulePath] };
}
