import { McpClient, type StdioServerConfig } from "@agent-deck/mcp";
import type { BridgeRegistry } from "./bridge.ts";

/**
 * Proxies configured MCP servers' tools onto the bridge. pi has no native MCP,
 * so the app runs an MCP client per configured server, lists its tools, and
 * registers each on the bridge as `mcp__<server>__<tool>`, forwarding calls to
 * the client. Best-effort: a server that fails to connect is reported and
 * skipped, never breaking server startup.
 */

export interface McpServerConfig extends StdioServerConfig {
  /** Stable id, used in the bridge tool name and for de-duplication. */
  id: string;
}

export interface McpRegistration {
  /** Close all MCP clients (killing their subprocesses). */
  close(): Promise<void>;
}

/** How long to wait for a single MCP server to connect + list its tools. */
const MCP_CONNECT_TIMEOUT_MS = 15_000;

/** Keep bridge tool names to pi-safe identifier characters. */
function sanitize(part: string): string {
  return part.replace(/[^A-Za-z0-9_]/g, "_");
}

function bridgeToolName(serverId: string, toolName: string): string {
  return `mcp__${sanitize(serverId)}__${sanitize(toolName)}`;
}

function withTimeout<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${label} timed out after ${ms}ms`)), ms);
    timer.unref();
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error: unknown) => {
        clearTimeout(timer);
        reject(error instanceof Error ? error : new Error(String(error)));
      },
    );
  });
}

/** Ensure the advertised parameters are a valid object JSON-Schema for pi. */
function normalizeParameters(inputSchema: Record<string, unknown>): Record<string, unknown> {
  if (inputSchema && typeof inputSchema === "object" && inputSchema.type === "object") {
    return inputSchema;
  }
  return { type: "object", properties: (inputSchema?.properties as unknown) ?? {} };
}

export async function registerMcpServers(
  bridge: BridgeRegistry,
  configs: McpServerConfig[],
  onError: (serverId: string, error: unknown) => void = () => {},
): Promise<McpRegistration> {
  const clients: McpClient[] = [];
  // Names already claimed on the bridge, so a sanitized-name collision (two
  // servers/tools mapping to the same mcp__…__… name) is surfaced, not silently
  // clobbered. Seed with what's already registered (e.g. the memory tools).
  const takenNames = new Set(bridge.specs().map((spec) => spec.name));
  const seenIds = new Set<string>();
  const unique = configs.filter((config) => {
    if (seenIds.has(config.id)) return false;
    seenIds.add(config.id);
    return true;
  });

  // Connect all servers in parallel with a per-server timeout — one slow or
  // hung server must not delay startup or block the others. Best-effort: a
  // failure is reported and that server is skipped.
  await Promise.allSettled(
    unique.map(async (config) => {
      let client: McpClient;
      try {
        client = await withTimeout(
          McpClient.connectStdio(config),
          MCP_CONNECT_TIMEOUT_MS,
          `MCP connect "${config.id}"`,
        );
      } catch (error) {
        onError(config.id, error);
        return;
      }
      try {
        const tools = await withTimeout(
          client.listTools(),
          MCP_CONNECT_TIMEOUT_MS,
          `MCP listTools "${config.id}"`,
        );
        clients.push(client);
        const safeServerId = sanitize(config.id);
        for (const tool of tools) {
          const name = bridgeToolName(config.id, tool.name);
          if (!safeServerId || !sanitize(tool.name) || takenNames.has(name)) {
            onError(
              config.id,
              new Error(`skipping tool with empty/colliding bridge name: ${name}`),
            );
            continue;
          }
          takenNames.add(name);
          bridge.register(
            {
              name,
              label: `${config.id}: ${tool.name}`,
              description: tool.description,
              parameters: normalizeParameters(tool.inputSchema),
            },
            // The original (unprefixed) MCP tool name + this server's client are
            // captured here, so the forward always targets the right tool.
            async (params) => {
              const result = await client.callTool(tool.name, params);
              return { content: result.content, isError: result.isError };
            },
          );
        }
      } catch (error) {
        onError(config.id, error);
      }
    }),
  );
  return {
    close: async () => {
      await Promise.all(clients.map((client) => client.close().catch(() => {})));
    },
  };
}

/** Parse AGENT_DECK_MCP_SERVERS (a JSON array of stdio server configs). */
export function mcpServerConfigsFromEnv(raw: string | undefined): McpServerConfig[] {
  if (!raw) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return [];
  }
  if (!Array.isArray(parsed)) return [];
  return parsed.filter(
    (entry): entry is McpServerConfig =>
      typeof entry === "object" &&
      entry !== null &&
      typeof (entry as McpServerConfig).id === "string" &&
      typeof (entry as McpServerConfig).command === "string",
  );
}
