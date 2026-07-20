import { existsSync, statSync } from "node:fs";
import nodePath from "node:path";
import { z } from "zod";

/** Resource names become file/dir names — never let them traverse paths. */
export const RESOURCE_NAME = z
  .string()
  .regex(/^[A-Za-z0-9][A-Za-z0-9._-]*$/, "invalid resource name");

/**
 * Finalize a session's --extension list: resolve, drop duplicates (loading the
 * same extension twice is wasteful/buggy), and skip anything that isn't a real
 * file right now (an added extension can be deleted or moved after the fact).
 */
export function finalizeExtensions(paths: Array<string | undefined>): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const raw of paths) {
    if (!raw) continue;
    const resolved = nodePath.resolve(raw);
    if (seen.has(resolved)) continue;
    seen.add(resolved);
    if (existsSync(resolved) && statSync(resolved).isFile()) out.push(resolved);
  }
  return out;
}

// Project instructions: pi auto-loads a context file every turn. It reads the
// FIRST of AGENTS.md / AGENTS.MD / CLAUDE.md / CLAUDE.MD it finds (AGENTS wins),
// so we edit that effective file — a CLAUDE.md project shows CLAUDE.md, not an
// empty AGENTS.md editor. A fresh location defaults to AGENTS.md.
export const instructionsBody = z.object({ content: z.string().max(200_000) });
const INSTRUCTION_FILENAMES = ["AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"];
export const resolveInstructionsFile = (dir: string): string => {
  for (const name of INSTRUCTION_FILENAMES) {
    const candidate = nodePath.join(dir, name);
    if (existsSync(candidate)) return candidate;
  }
  return nodePath.join(dir, "AGENTS.md");
};

export const INSTRUCTIONS_MAX = 1_000_000;
