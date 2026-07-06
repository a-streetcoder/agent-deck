import { readFileSync } from "node:fs";
import path from "node:path";
import { piAgentHome, type ResourceRoots } from "./paths.ts";

/**
 * MCP server configuration, in the standard mcp.json format shared with pi's
 * ecosystem: `{ mcpServers: { "<name>": { command, args, env } | { url } } }`.
 * Read from the project (`<project>/.pi/mcp.json`) and global
 * (`~/.pi/agent/mcp.json`) locations; a project entry overrides a global one of
 * the same name. This is the read/merge half — the app-owned write path lands
 * with the config UI.
 */

export type McpTransport = "stdio" | "http";
export type McpConfigScope = "global" | "project";

/** A normalized MCP server config resolved from an mcp.json entry. */
export interface McpServerEntry {
  /** The mcpServers key. */
  id: string;
  transport: McpTransport;
  /** stdio transport. */
  command?: string;
  args?: string[];
  env?: Record<string, string>;
  /** http/sse transport. */
  url?: string;
  scope: McpConfigScope;
}

/** The mcp.json path for a scope (project needs a projectPath; else undefined). */
export function mcpConfigPath(roots: ResourceRoots, scope: McpConfigScope): string | undefined {
  if (scope === "project") {
    return roots.projectPath ? path.join(roots.projectPath, ".pi", "mcp.json") : undefined;
  }
  return path.join(piAgentHome(roots), "mcp.json");
}

function asStringRecord(value: unknown): Record<string, string> | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const out: Record<string, string> = {};
  for (const [key, val] of Object.entries(value as Record<string, unknown>)) {
    if (typeof val === "string") out[key] = val;
  }
  return Object.keys(out).length > 0 ? out : undefined;
}

/** Parse one mcp.json file's entries into normalized configs (invalid → skipped). */
function parseMcpFile(file: string, scope: McpConfigScope): McpServerEntry[] {
  let data: unknown;
  try {
    data = JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return [];
  }
  const servers = (data as { mcpServers?: unknown })?.mcpServers;
  if (typeof servers !== "object" || servers === null) return [];
  const entries: McpServerEntry[] = [];
  for (const [id, raw] of Object.entries(servers as Record<string, unknown>)) {
    if (typeof raw !== "object" || raw === null) continue;
    const config = raw as Record<string, unknown>;
    if (typeof config.command === "string") {
      entries.push({
        id,
        transport: "stdio",
        command: config.command,
        args: Array.isArray(config.args)
          ? config.args.filter((a): a is string => typeof a === "string")
          : undefined,
        env: asStringRecord(config.env),
        scope,
      });
    } else if (typeof config.url === "string") {
      entries.push({ id, transport: "http", url: config.url, scope });
    }
    // Neither command nor url → not a usable server; skip.
  }
  return entries;
}

/**
 * All configured MCP servers, project entries overriding global ones by id.
 * Missing files are simply absent.
 */
export function readMcpServers(roots: ResourceRoots): McpServerEntry[] {
  const byId = new Map<string, McpServerEntry>();
  const globalPath = mcpConfigPath(roots, "global");
  if (globalPath) for (const entry of parseMcpFile(globalPath, "global")) byId.set(entry.id, entry);
  const projectPath = mcpConfigPath(roots, "project");
  if (projectPath)
    for (const entry of parseMcpFile(projectPath, "project")) byId.set(entry.id, entry);
  return [...byId.values()];
}
