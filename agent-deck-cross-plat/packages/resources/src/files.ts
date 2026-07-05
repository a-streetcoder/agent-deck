import { readdirSync, type Dirent } from "node:fs";
import path from "node:path";

/**
 * Bounded, breadth-first project file listing for `@`-file autocomplete.
 * Skips VCS/build/hidden noise and caps total results so a large repo can't
 * stall the sync walk.
 */

const SKIP_DIRS = new Set([
  ".git",
  "node_modules",
  "dist",
  "build",
  ".next",
  ".turbo",
  "target",
  ".venv",
  "venv",
  "__pycache__",
  ".DS_Store",
  "coverage",
  ".pnpm",
]);

const MAX_RESULTS = 500;
const MAX_VISITED_DIRS = 2000;

/**
 * Return project-relative file paths under `root`, filtered by a case-
 * insensitive substring `query` (empty = all, up to the cap). Symlinked
 * entries are skipped via withFileTypes (no follow).
 */
export function listProjectFiles(root: string, query = ""): string[] {
  const needle = query.trim().toLowerCase();
  const results: string[] = [];
  const queue: string[] = [root];
  let visited = 0;

  while (queue.length > 0 && results.length < MAX_RESULTS && visited < MAX_VISITED_DIRS) {
    const dir = queue.shift()!;
    visited += 1;
    let entries: Dirent[];
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      if (entry.name.startsWith(".") || SKIP_DIRS.has(entry.name)) continue;
      const full = path.join(dir, entry.name);
      if (entry.isSymbolicLink()) continue; // never follow links out of the project
      if (entry.isDirectory()) {
        queue.push(full);
      } else if (entry.isFile()) {
        const rel = path.relative(root, full);
        if (needle === "" || rel.toLowerCase().includes(needle)) {
          results.push(rel);
          if (results.length >= MAX_RESULTS) break;
        }
      }
    }
  }
  // Shorter paths (usually more relevant) first, then alphabetical.
  return results.sort((a, b) => a.length - b.length || a.localeCompare(b));
}
