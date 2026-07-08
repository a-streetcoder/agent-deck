import {
  McpClient,
  type HttpServerConfig,
  type McpOAuthProvider,
  type StdioServerConfig,
} from "@agent-deck/mcp";
import { isValidHttpMcpUrl } from "@agent-deck/resources";
import type { BridgeRegistry } from "./bridge.ts";

/**
 * Proxies configured MCP servers' tools onto the bridge and owns their live
 * connection lifecycle. pi has no native MCP, so the app runs an MCP client per
 * configured server, lists its tools, and registers each on the bridge as
 * `mcp__<server>__<tool>`, forwarding calls to the client. The manager tracks
 * per-server state so the UI can show what connected and add/remove/refresh
 * servers at runtime.
 */

/** A configured MCP server: stdio (spawned) or http (remote Streamable HTTP),
 * discriminated by whether it carries a `url`. */
export type McpServerConfig = { id: string } & (StdioServerConfig | HttpServerConfig);

/** True for an http (Streamable HTTP) server config. */
function isHttpConfig(config: McpServerConfig): config is { id: string } & HttpServerConfig {
  return "url" in config && typeof config.url === "string";
}

/** Live state of one configured MCP server (for GET /mcp). */
export interface McpServerStatus {
  id: string;
  transport: "stdio" | "http";
  connected: boolean;
  /** Bridge tool names (mcp__<id>__<tool>) currently registered for this server. */
  toolNames: string[];
  /** Present when the last connect/list attempt failed. */
  error?: string;
}

/** How long to wait for a single MCP server to connect + list its tools. */
const MCP_CONNECT_TIMEOUT_MS = 15_000;

/** Keep bridge tool names to pi-safe identifier characters. */
function sanitize(part: string): string {
  return part.replace(/[^A-Za-z0-9_]/g, "_");
}

const MCP_TOOL_PREFIX = "mcp__";

function bridgeToolName(serverId: string, toolName: string): string {
  return `${MCP_TOOL_PREFIX}${sanitize(serverId)}__${sanitize(toolName)}`;
}

/**
 * Per-session MCP scoping: keep every non-MCP bridge tool, but keep an MCP tool
 * (mcp__<server>__<tool>) only if its server is in `allowedServerIds`. Used to
 * expose ONLY the MCP servers an agent declared (agent.mcpServers) to its
 * sessions; an empty allowlist drops all MCP tools. Pure + name-based so it needs
 * no live manager state.
 */
export function scopeMcpBridgeSpecs<T extends { name: string }>(
  specs: T[],
  allowedServerIds: string[],
): T[] {
  const allowedPrefixes = allowedServerIds.map((id) => `${MCP_TOOL_PREFIX}${sanitize(id)}__`);
  return specs.filter(
    (spec) =>
      !spec.name.startsWith(MCP_TOOL_PREFIX) ||
      allowedPrefixes.some((prefix) => spec.name.startsWith(prefix)),
  );
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

interface ServerState {
  config: McpServerConfig;
  client?: McpClient;
  /** Bridge names registered for this server (for unregister on teardown). */
  toolNames: string[];
  error?: string;
}

export class McpManager {
  private readonly servers = new Map<string, ServerState>();
  /** Per-id operation chain so connect/refresh/remove for one id never interleave. */
  private readonly locks = new Map<string, Promise<unknown>>();
  /** Supplies the OAuth provider for an authed http server (undefined → none). */
  private readonly httpAuthProvider?: (id: string) => McpOAuthProvider | undefined;

  constructor(
    private readonly bridge: BridgeRegistry,
    options: { httpAuthProvider?: (id: string) => McpOAuthProvider | undefined } = {},
  ) {
    this.httpAuthProvider = options.httpAuthProvider;
  }

  /** The Streamable-HTTP url a configured server connects to (for OAuth), if any. */
  httpUrlFor(id: string): string | undefined {
    const config = this.servers.get(id)?.config;
    return config && isHttpConfig(config) ? config.url : undefined;
  }

  /** Serialize an operation for one server id behind any in-flight op for it. */
  private serialize<T>(id: string, op: () => Promise<T>): Promise<T> {
    const prev = this.locks.get(id) ?? Promise.resolve();
    const next = prev.then(op, op);
    // Store a non-rejecting tail so the next op always runs after this settles.
    this.locks.set(
      id,
      next.then(
        () => undefined,
        () => undefined,
      ),
    );
    return next;
  }

  /** Live state of every server the manager has attempted to connect. */
  status(): McpServerStatus[] {
    return [...this.servers.values()].map((state) => ({
      id: state.config.id,
      transport: isHttpConfig(state.config) ? "http" : "stdio",
      connected: state.client !== undefined,
      toolNames: [...state.toolNames],
      error: state.error,
    }));
  }

  has(id: string): boolean {
    return this.servers.has(id);
  }

  /** Unregister a server's tools, close its client, and drop it. */
  private async teardown(id: string): Promise<void> {
    const state = this.servers.get(id);
    if (!state) return;
    for (const name of state.toolNames) this.bridge.unregister(name);
    await state.client?.close().catch(() => {});
    this.servers.delete(id);
  }

  /**
   * Connect (or reconnect) one server: any prior registration for the id is torn
   * down first. A connect/list failure is recorded on the state (not thrown), so
   * one bad server never breaks the others or startup.
   */
  connect(config: McpServerConfig): Promise<McpServerStatus> {
    return this.serialize(config.id, () => this.connectInner(config));
  }

  private async connectInner(config: McpServerConfig): Promise<McpServerStatus> {
    await this.teardown(config.id);
    const state: ServerState = { config, toolNames: [] };
    this.servers.set(config.id, state);
    try {
      const client = await withTimeout(
        isHttpConfig(config)
          ? McpClient.connectHttp(config, { authProvider: this.httpAuthProvider?.(config.id) })
          : McpClient.connectStdio(config),
        MCP_CONNECT_TIMEOUT_MS,
        `MCP connect "${config.id}"`,
      );
      const tools = await withTimeout(
        client.listTools(),
        MCP_CONNECT_TIMEOUT_MS,
        `MCP listTools "${config.id}"`,
      );
      state.client = client;
      const safeId = sanitize(config.id);
      for (const tool of tools) {
        const name = bridgeToolName(config.id, tool.name);
        // Skip empty-segment or already-claimed names (memory tools, other
        // servers) rather than silently clobber the bridge registry.
        if (!safeId || !sanitize(tool.name) || this.bridge.specs().some((s) => s.name === name)) {
          continue;
        }
        state.toolNames.push(name);
        this.bridge.register(
          {
            name,
            label: `${config.id}: ${tool.name}`,
            description: tool.description,
            parameters: normalizeParameters(tool.inputSchema),
          },
          async (params) => {
            const result = await client.callTool(tool.name, params);
            return { content: result.content, isError: result.isError };
          },
        );
      }
    } catch (error) {
      state.error = error instanceof Error ? error.message : String(error);
    }
    return this.status().find((s) => s.id === config.id)!;
  }

  /** Connect many servers in parallel (startup). Best-effort per server. */
  async connectAll(configs: McpServerConfig[]): Promise<void> {
    const seen = new Set<string>();
    const unique = configs.filter((config) => {
      if (seen.has(config.id)) return false;
      seen.add(config.id);
      return true;
    });
    await Promise.allSettled(unique.map((config) => this.connect(config)));
  }

  /** Reconnect a known server using its stored config. */
  refresh(id: string): Promise<McpServerStatus | null> {
    return this.serialize(id, async () => {
      const config = this.servers.get(id)?.config;
      // connectInner (not connect) — we already hold this id's lock.
      return config ? await this.connectInner(config) : null;
    });
  }

  /** Remove a server: unregister its tools and close its client. */
  remove(id: string): Promise<boolean> {
    return this.serialize(id, async () => {
      if (!this.servers.has(id)) return false;
      await this.teardown(id);
      return true;
    });
  }

  async close(): Promise<void> {
    await Promise.all([...this.servers.keys()].map((id) => this.teardown(id)));
  }
}

/** Parse AGENT_DECK_MCP_SERVERS (a JSON array of server configs, stdio or http). */
export function mcpServerConfigsFromEnv(raw: string | undefined): McpServerConfig[] {
  if (!raw) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return [];
  }
  if (!Array.isArray(parsed)) return [];
  return parsed.filter((entry): entry is McpServerConfig => {
    if (typeof entry !== "object" || entry === null) return false;
    const e = entry as { id?: unknown; command?: unknown; url?: unknown };
    if (typeof e.id !== "string") return false;
    const hasCommand = typeof e.command === "string";
    const hasUrl = e.url !== undefined;
    // Exactly one transport (never both/neither — a dual entry would silently
    // drop `command` since url wins), and any http url must be well-formed http(s).
    if (hasCommand === hasUrl) return false;
    if (hasUrl) return isValidHttpMcpUrl(e.url);
    return true;
  });
}
