import { existsSync, realpathSync } from "node:fs";
import nodePath from "node:path";

/**
 * The shared path-containment gate (Slice 13a extracted this out of Slice 11's
 * editorLauncher.ts so the file-navigation endpoints reuse the EXACT same
 * check — never a subtly-different reimplementation).
 *
 * Resolve a repo-RELATIVE path against a session's cwd, rejecting anything that
 * escapes it: absolute inputs, `..` traversal, and symlinks pointing outside
 * (realpath containment — the resolved REAL path must stay under the cwd's real
 * path). The target must exist. Returns the absolute CANONICAL (realpath) path,
 * which shrinks the check-to-use TOCTOU window.
 *
 * `allowBase` controls whether the cwd ITSELF is a legal target: editor-open
 * (a file) leaves it false (opening the directory is meaningless), while the
 * directory-listing endpoint sets it true so the project root can be listed.
 */
export function resolveContainedPath(
  cwd: string,
  relativePath: string,
  options: { allowBase?: boolean } = {},
): string {
  const allowBase = options.allowBase ?? false;
  if (relativePath.includes("\0")) throw new Error("invalid path");
  if (nodePath.isAbsolute(relativePath)) {
    throw new Error("path must be relative to the session directory");
  }
  const absCwd = nodePath.resolve(cwd);
  const abs = nodePath.resolve(absCwd, relativePath);
  if (!withinBase(absCwd, abs, allowBase)) {
    throw new Error("path escapes the session directory");
  }
  if (!existsSync(abs)) throw new Error("file not found");
  // Symlink escape: compare REAL paths too, so a link inside the cwd can't
  // smuggle the target outside it.
  const realAbs = realpathSync(abs);
  const realCwd = realpathSync(absCwd);
  if (!withinBase(realCwd, realAbs, allowBase)) {
    throw new Error("path escapes the session directory");
  }
  return realAbs;
}

/**
 * Is `target` contained within `base`? Segment-aware: a bare
 * `startsWith("..")` would also reject a sibling literally NAMED "..foo"
 * (legal on NTFS/POSIX), so only an exact ".." or a "../"-prefixed relative
 * path escapes. `target === base` (empty relative) counts as contained only
 * when `allowBase` is set.
 */
function withinBase(base: string, target: string, allowBase: boolean): boolean {
  const rel = nodePath.relative(base, target);
  if (rel === "") return allowBase;
  return rel !== ".." && !rel.startsWith(`..${nodePath.sep}`) && !nodePath.isAbsolute(rel);
}
