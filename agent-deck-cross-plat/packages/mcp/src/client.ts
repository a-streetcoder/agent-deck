import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import {
  getDefaultEnvironment,
  StdioClientTransport,
} from "@modelcontextprotocol/sdk/client/stdio.js";
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js";

/**
 * A thin wrapper over an MCP client connection. pi core has no built-in MCP
 * (concepts/pi-runtime-vs-agent-deck.md), so Agent Deck proxies a configured
 * MCP server's tools into pi sessions over the bridge substrate: the server
 * lists an MCP server's tools and forwards each call here. This package stays
 * MCP-focused; apps/server maps these tools onto the bridge.
 */

/** A tool exposed by an MCP server. */
export interface McpToolInfo {
  name: string;
  description: string;
  /** JSON-Schema object for the tool's arguments (from the MCP server). */
  inputSchema: Record<string, unknown>;
}

/** The result of forwarding a tool call to the MCP server. */
export interface McpCallResult {
  /** Flattened text content returned to the model. */
  content: string;
  isError: boolean;
}

/** A stdio MCP server the app spawns and talks to over its stdin/stdout. */
export interface StdioServerConfig {
  command: string;
  args?: string[];
  env?: Record<string, string>;
  cwd?: string;
}

function flattenContent(content: unknown): string {
  if (!Array.isArray(content)) return "";
  return content
    .map((part) =>
      typeof part === "object" && part !== null && "text" in part
        ? String((part as { text: unknown }).text)
        : "",
    )
    .join("");
}

export class McpClient {
  private constructor(private readonly client: Client) {}

  /** Connect to an already-constructed transport (used by tests via in-memory). */
  static async connect(transport: Transport, name = "agent-deck"): Promise<McpClient> {
    const client = new Client({ name, version: "0.0.1" });
    await client.connect(transport);
    return new McpClient(client);
  }

  /** Spawn and connect to a stdio MCP server. */
  static async connectStdio(config: StdioServerConfig): Promise<McpClient> {
    const transport = new StdioClientTransport({
      command: config.command,
      args: config.args,
      // Merge over the SDK's safe default env (PATH/HOME/…): passing only the
      // custom vars would otherwise drop them and the server couldn't launch.
      env: config.env ? { ...getDefaultEnvironment(), ...config.env } : undefined,
      cwd: config.cwd,
    });
    return await McpClient.connect(transport);
  }

  /** List the server's tools as plain JSON-Schema-carrying descriptors. */
  async listTools(): Promise<McpToolInfo[]> {
    const { tools } = await this.client.listTools();
    return tools.map((tool) => ({
      name: tool.name,
      description: tool.description ?? tool.name,
      inputSchema: (tool.inputSchema as Record<string, unknown> | undefined) ?? {
        type: "object",
        properties: {},
      },
    }));
  }

  /** Forward a tool call to the MCP server and flatten its result. */
  async callTool(name: string, args: Record<string, unknown>): Promise<McpCallResult> {
    const result = await this.client.callTool({ name, arguments: args });
    return {
      content: flattenContent(result.content),
      isError: result.isError === true,
    };
  }

  async close(): Promise<void> {
    await this.client.close();
  }
}
