import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import path from "node:path";
import type { ResourceScope } from "@agent-deck/domain";
import { piAgentHome, type ResourceRoots } from "./paths.ts";

export type EnvScope = Extract<ResourceScope, "global" | "project">;

/**
 * Read-only view of pi's .env files (~/.pi/agent/.env and PROJECT/.pi/.env,
 * per file-locations.md). Values are masked — this is a presence/override
 * inspector, never a secret exfiltration surface.
 */

export interface EnvEntry {
  key: string;
  /** Masked preview (e.g. "sk-…4f2a") — never the full value. */
  masked: string;
  scope: Extract<ResourceScope, "global" | "project">;
  /** A global entry shadowed by a project entry of the same key. */
  overridden: boolean;
}

function maskValue(value: string): string {
  const trimmed = value.trim();
  if (trimmed.length === 0) return "";
  if (trimmed.length <= 4) return "•".repeat(trimmed.length);
  return `${"•".repeat(Math.min(8, trimmed.length - 4))}${trimmed.slice(-4)}`;
}

/** Minimal dotenv parse: KEY=VALUE lines, ignoring comments and blanks. */
function parseEnv(content: string): Map<string, string> {
  const entries = new Map<string, string>();
  for (const rawLine of content.split("\n")) {
    const line = rawLine.trim();
    if (line.length === 0 || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq === -1) continue;
    const key = line.slice(0, eq).trim();
    if (!key) continue;
    let value = line.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    entries.set(key, value);
  }
  return entries;
}

function readEnvFile(filePath: string): Map<string, string> {
  try {
    return parseEnv(readFileSync(filePath, "utf8"));
  } catch {
    return new Map();
  }
}

export function scanEnv(roots: ResourceRoots): EnvEntry[] {
  const globalEnv = readEnvFile(path.join(piAgentHome(roots), ".env"));
  const projectEnv = roots.projectPath
    ? readEnvFile(path.join(roots.projectPath, ".pi", ".env"))
    : new Map<string, string>();

  const entries: EnvEntry[] = [];
  for (const [key, value] of globalEnv) {
    entries.push({
      key,
      masked: maskValue(value),
      scope: "global",
      overridden: projectEnv.has(key),
    });
  }
  for (const [key, value] of projectEnv) {
    entries.push({ key, masked: maskValue(value), scope: "project", overridden: false });
  }
  return entries.sort((a, b) => a.key.localeCompare(b.key));
}

function envFilePath(roots: ResourceRoots, scope: EnvScope): string {
  if (scope === "global") return path.join(piAgentHome(roots), ".env");
  if (!roots.projectPath) throw new Error("projectId required for the project env file");
  return path.join(roots.projectPath, ".pi", ".env");
}

/**
 * Preserve unknown lines (comments, blanks, ordering) on write. Only the
 * KEY=VALUE line for `key` is edited/appended; a null `value` deletes it.
 * Values with whitespace/special chars are double-quoted.
 */
function serializeEnvValue(value: string): string {
  if (value === "" || /[\s"'#=]/.test(value)) {
    return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
  }
  return value;
}

function isKeyLine(line: string, key: string): boolean {
  const trimmed = line.trim();
  if (trimmed.length === 0 || trimmed.startsWith("#")) return false;
  const eq = trimmed.indexOf("=");
  return eq !== -1 && trimmed.slice(0, eq).trim() === key;
}

/** Set (or with null, delete) one env var, preserving all other lines. */
export function writeEnvVar(
  roots: ResourceRoots,
  scope: EnvScope,
  key: string,
  value: string | null,
): void {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) {
    throw new Error(`invalid env key: ${key}`);
  }
  const filePath = envFilePath(roots, scope);
  let lines: string[] = [];
  try {
    lines = readFileSync(filePath, "utf8").split("\n");
  } catch {
    // New file.
  }
  const kept = lines.filter((line) => !isKeyLine(line, key));
  // Drop a trailing empty element from split so we don't accumulate blanks.
  while (kept.length > 0 && kept[kept.length - 1]!.trim() === "") kept.pop();
  if (value !== null) kept.push(`${key}=${serializeEnvValue(value)}`);

  mkdirSync(path.dirname(filePath), { recursive: true });
  const content = kept.length > 0 ? `${kept.join("\n")}\n` : "";
  const tmp = `${filePath}.tmp`;
  writeFileSync(tmp, content);
  renameSync(tmp, filePath); // atomic replace
}
