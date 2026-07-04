import { readFileSync } from "node:fs";
import path from "node:path";
import type { ResourceScope } from "@agent-deck/domain";
import { piAgentHome, type ResourceRoots } from "./paths.ts";

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
