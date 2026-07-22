import type { Dirent } from "node:fs";
import {
  chmod,
  mkdir,
  open,
  readdir,
  rename,
  stat,
  unlink,
  writeFile as fsWriteFile,
} from "node:fs/promises";
import nodePath from "node:path";
import {
  FILE_IMAGE_MAX_BYTES,
  FILE_LIST_MAX_ENTRIES,
  FILE_READ_MAX_BYTES,
  type FileContentKind,
  type FileListEntry,
} from "@agent-deck/contracts";
import { resolveContainedPath } from "../pathContainment.ts";

/**
 * File-navigation service (Slice 13a) — browse a session's project tree one
 * directory at a time and read one file bounded. Ported from the shapes in
 * t3code's `apps/server/src/workspace/WorkspaceEntries.ts` (directory browse)
 * and `WorkspaceFileSystem.ts` (bounded, containment-guarded read) (MIT), and
 * condensed onto this repo's plain-module facade idiom — editorLauncher.ts is
 * the template (one-shot fs probes need no Effect scope; the rpcHandler
 * consumes the object facade exactly like the editor/terminal/diff gateways).
 *
 * SECURITY (the slice's gate): every path is repo-RELATIVE and resolved INSIDE
 * the session's cwd through the SHARED {@link resolveContainedPath} — the same
 * segment-aware `..` / absolute / symlink-realpath containment editorLauncher
 * uses (never a subtly-different reimplementation). The listing sets
 * `allowBase` so the project ROOT is a legal target; a read leaves it false.
 * The cwd always comes from the session record server-side, never the wire.
 *
 * Policy (follows the donor's directory browse):
 *   - No `.gitignore` filtering — a plain filesystem view. The donor's
 *     gitignore-aware surface is its recursive ripgrep search index, a
 *     separate thing not ported here.
 *   - Symlinked entries are omitted from listings (the donor never follows
 *     links out of the project); an escaping link would be caught by the
 *     containment gate on the follow-up list/read anyway.
 *   - No caching (the donor's read is on-demand; the browse has no cache).
 */

// ---------------------------------------------------------------------------
// Shape + result types
// ---------------------------------------------------------------------------

/** One directory's listing (the `file_list_ok` payload). */
export interface FileListResult {
  /** The listed directory, relative to the project root ("" for the root). */
  readonly path: string;
  readonly entries: readonly FileListEntry[];
  /** True when the listing was capped at the max-entries bound. */
  readonly truncated: boolean;
}

/** One file's bounded content (the `file_read_ok` payload). */
export interface FileReadResult {
  readonly contentKind: FileContentKind;
  /** Text, a `data:` image URI, or "" (binary). */
  readonly content: string;
  /** The file's true size on disk, in bytes. */
  readonly byteLength: number;
  /** True when a text file was capped at the read bound. */
  readonly truncated: boolean;
  /** The version token (`${mtimeMs}:${byteLength}`) — the conflict guard's base. */
  readonly version: string;
}

/** One file's write outcome (the `file_write_ok` payload). `conflict` means the
 * on-disk version drifted since read — the write was REFUSED (the buffer is
 * kept client-side) and `version` is the CURRENT on-disk token. `written` means
 * the atomic replace landed and `version` is the file's NEW token. */
export interface FileWriteResult {
  readonly outcome: "written" | "conflict";
  readonly version: string;
}

export interface FileService {
  /** List one directory within the session's project (relPath "" = root). */
  readonly listDirectory: (cwd: string, relPath?: string) => Promise<FileListResult>;
  /** Read one file of the session's project, bounded (text/image/binary). */
  readonly readFile: (cwd: string, relPath: string) => Promise<FileReadResult>;
  /**
   * Overwrite one EXISTING text file (Slice L4b). Rejects a path that escapes
   * the cwd or does not exist (same containment as {@link readFile}); when the
   * on-disk version differs from `baseVersion` returns a `conflict` WITHOUT
   * writing; otherwise writes atomically (temp + rename) and returns `written`
   * with the file's new version token.
   */
  readonly writeFile: (
    cwd: string,
    relPath: string,
    content: string,
    baseVersion: string,
  ) => Promise<FileWriteResult>;
}

export interface FileServiceOptions {
  /** Text read cap in bytes (tests); defaults to the wire-contract cap. */
  readonly maxReadBytes?: number;
  /** Inline-image cap in bytes (tests); defaults to the wire-contract cap. */
  readonly maxImageBytes?: number;
  /** Listing entry cap (tests); defaults to the wire-contract cap. */
  readonly maxEntries?: number;
}

// ---------------------------------------------------------------------------
// Image handling (extension → MIME; the donor's SAFE_IMAGE_FILE_EXTENSIONS)
// ---------------------------------------------------------------------------

const IMAGE_MIME_BY_EXTENSION: Record<string, string> = {
  ".apng": "image/apng",
  ".avif": "image/avif",
  ".bmp": "image/bmp",
  ".gif": "image/gif",
  ".ico": "image/x-icon",
  ".jpeg": "image/jpeg",
  ".jpg": "image/jpeg",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".webp": "image/webp",
};

const imageMimeFor = (name: string): string | undefined =>
  IMAGE_MIME_BY_EXTENSION[nodePath.extname(name).toLowerCase()];

/** How many entry stats may be in flight at once (EMFILE guard). */
const STAT_CONCURRENCY = 32;

async function mapWithConcurrency<T, R>(
  items: readonly T[],
  concurrency: number,
  fn: (item: T) => Promise<R>,
): Promise<R[]> {
  const results = new Array<R>(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (next < items.length) {
      const index = next;
      next += 1;
      results[index] = await fn(items[index]!);
    }
  });
  await Promise.all(workers);
  return results;
}

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

export function createFileService(options: FileServiceOptions = {}): FileService {
  const maxReadBytes = options.maxReadBytes ?? FILE_READ_MAX_BYTES;
  const maxImageBytes = options.maxImageBytes ?? FILE_IMAGE_MAX_BYTES;
  const maxEntries = options.maxEntries ?? FILE_LIST_MAX_ENTRIES;

  const listDirectory = async (cwd: string, relPath = ""): Promise<FileListResult> => {
    // "" / "." → the project root itself, which the containment gate permits
    // only with allowBase. A missing/escaping/non-relative path throws.
    const normalized = relPath === "." ? "" : relPath;
    const absDir = resolveContainedPath(cwd, normalized, { allowBase: true });
    const dirStat = await stat(absDir);
    if (!dirStat.isDirectory()) throw new Error("not a directory");

    const dirents = await readdir(absDir, { withFileTypes: true });
    // Files + subdirectories only; symlinks and specials are skipped (see the
    // module doc). Directories first, then files, each alphabetical — the shape
    // a lazy file tree wants.
    const kept: Array<{ dirent: Dirent; kind: "file" | "dir" }> = [];
    for (const dirent of dirents) {
      if (dirent.isSymbolicLink()) continue;
      if (dirent.isDirectory()) kept.push({ dirent, kind: "dir" });
      else if (dirent.isFile()) kept.push({ dirent, kind: "file" });
    }
    kept.sort((a, b) => {
      if (a.kind !== b.kind) return a.kind === "dir" ? -1 : 1;
      return a.dirent.name.localeCompare(b.dirent.name);
    });

    const truncated = kept.length > maxEntries;
    const capped = kept.slice(0, maxEntries);
    const entries = await mapWithConcurrency(capped, STAT_CONCURRENCY, async ({ dirent, kind }) => {
      if (kind === "dir") {
        return { name: dirent.name, kind: "dir", size: null } satisfies FileListEntry;
      }
      // A file that vanished mid-scan reports size 0 rather than failing the
      // whole listing.
      let size = 0;
      try {
        size = (await stat(nodePath.join(absDir, dirent.name))).size;
      } catch {
        size = 0;
      }
      return { name: dirent.name, kind: "file", size } satisfies FileListEntry;
    });

    return { path: normalized, entries, truncated };
  };

  const readFile = async (cwd: string, relPath: string): Promise<FileReadResult> => {
    const abs = resolveContainedPath(cwd, relPath);
    // Stat BEFORE opening: opening a directory throws EISDIR on some platforms
    // (Windows) with an opaque message — reject it cleanly here instead.
    const fileStat = await stat(abs);
    if (!fileStat.isFile()) throw new Error("not a file");
    const byteLength = fileStat.size;
    const version = versionToken(fileStat);
    const mime = imageMimeFor(nodePath.basename(abs));

    const handle = await open(abs, "r");
    try {
      // A recognised image within the inline cap → a whole-file data URI.
      // Over the cap it can't be previewed inline, so it degrades to binary.
      if (mime !== undefined) {
        if (byteLength > maxImageBytes) {
          return { contentKind: "binary", content: "", byteLength, truncated: false, version };
        }
        const buffer = Buffer.alloc(byteLength);
        await handle.read(buffer, 0, byteLength, 0);
        const content = `data:${mime};base64,${buffer.toString("base64")}`;
        return { contentKind: "image", content, byteLength, truncated: false, version };
      }

      // Otherwise read a bounded prefix and sniff for binary (a NUL byte,
      // exactly the donor's check) before decoding as UTF-8 text.
      const bytesToRead = Math.min(byteLength, maxReadBytes);
      const buffer = Buffer.alloc(bytesToRead);
      const { bytesRead } = await handle.read(buffer, 0, bytesToRead, 0);
      const bytes = buffer.subarray(0, bytesRead);
      if (bytes.includes(0)) {
        return { contentKind: "binary", content: "", byteLength, truncated: false, version };
      }
      return {
        contentKind: "text",
        content: new TextDecoder("utf-8").decode(bytes),
        byteLength,
        truncated: byteLength > maxReadBytes,
        version,
      };
    } finally {
      await handle.close();
    }
  };

  const writeFile = async (
    cwd: string,
    relPath: string,
    content: string,
    baseVersion: string,
  ): Promise<FileWriteResult> => {
    // Same containment gate as a read (existing target, no create, no escape).
    const abs = resolveContainedPath(cwd, relPath);
    const before = await stat(abs);
    if (!before.isFile()) throw new Error("not a file");

    // The conflict guard: re-stat and compare JUST before the write. If the pi
    // agent (or an external editor) touched the file since the client read it,
    // its version token has drifted — refuse the write and report the current
    // token so the client keeps its buffer and offers a reload. A small TOCTOU
    // window between this compare and the rename is accepted (the requirement).
    const currentVersion = versionToken(before);
    if (currentVersion !== baseVersion) {
      return { outcome: "conflict", version: currentVersion };
    }

    await writeFileStringAtomically(abs, content, before.mode);
    const after = await stat(abs);
    return { outcome: "written", version: versionToken(after) };
  };

  return { listDirectory, readFile, writeFile };
}

/** The opaque version token: mtime + ctime + size. Any content change bumps
 * mtime/size; ctime (inode change time) also moves on an in-place rewrite, so a
 * same-length edit in the same mtime tick on a coarse-mtime FS still drifts. */
function versionToken(s: { mtimeMs: number; ctimeMs: number; size: number }): string {
  return `${s.mtimeMs}:${s.ctimeMs}:${s.size}`;
}

/**
 * Atomic file replace (ported from t3code's `writeFileStringAtomically`, plain
 * fs — no Effect): write the full content to a sibling temp file, then `rename`
 * it over the target. `rename` within a directory is atomic on POSIX and best-
 * effort on Windows, so a concurrent reader never sees a half-written file.
 */
async function writeFileStringAtomically(
  targetPath: string,
  contents: string,
  originalMode?: number,
): Promise<void> {
  const dir = nodePath.dirname(targetPath);
  await mkdir(dir, { recursive: true });
  // A unique sibling temp (same directory, so the rename stays on one volume).
  const tempPath = nodePath.join(
    dir,
    `.${nodePath.basename(targetPath)}.${process.pid}.${Date.now()}.${Math.random()
      .toString(36)
      .slice(2, 8)}.tmp`,
  );
  await fsWriteFile(tempPath, contents, "utf-8");
  // Preserve the original file's permission bits (a fresh temp otherwise gets
  // default umask perms — e.g. an executable script would lose its +x).
  // Best-effort: chmod is a no-op / unsupported on some platforms (Windows).
  if (originalMode !== undefined) {
    try {
      await chmod(tempPath, originalMode);
    } catch {
      /* best-effort */
    }
  }
  try {
    await rename(tempPath, targetPath);
  } catch (error) {
    // Never leave the sibling .tmp behind (it would also surface in file_list).
    try {
      await unlink(tempPath);
    } catch {
      /* already gone */
    }
    throw error;
  }
}
