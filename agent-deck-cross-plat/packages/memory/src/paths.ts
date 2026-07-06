import { createHash } from "node:crypto";
import path from "node:path";

/**
 * Memory is stored per project under a base directory the app owns (the
 * server's data dir). The project id is a stable hash of the standardized
 * project path, so the same repo maps to the same store regardless of how its
 * path was spelled, and one repo can never read another's memory.
 */

/** Normalize a project path so equivalent spellings hash identically. */
export function standardizeProjectPath(projectPath: string): string {
  const resolved = path.resolve(projectPath);
  // Drop a trailing separator, but keep at least one char so the filesystem
  // root ("/", "C:\\") doesn't collapse to empty; lowercase on case-insensitive
  // platforms.
  const trimmed = resolved.replace(/(.)[/\\]+$/, "$1");
  return process.platform === "win32" ? trimmed.toLowerCase() : trimmed;
}

/** Stable id for a project's memory directory. */
export function projectMemoryId(projectPath: string): string {
  return createHash("sha256")
    .update(standardizeProjectPath(projectPath))
    .digest("hex")
    .slice(0, 16);
}

/** The directory holding one project's memory files. */
export function projectMemoryDir(baseDir: string, projectPath: string): string {
  return path.join(baseDir, "projects", projectMemoryId(projectPath));
}

export function memoryFilePath(baseDir: string, projectPath: string, id: string): string {
  return path.join(projectMemoryDir(baseDir, projectPath), `${id}.md`);
}
