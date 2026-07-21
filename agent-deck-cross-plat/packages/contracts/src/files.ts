import { Schema } from "effect";
import { DiffPath } from "./diff.ts";

/**
 * File-navigation wire contract (Slice 13a) — browse a session's project tree
 * one directory at a time and read one file's content bounded. Shaped from
 * t3code's `apps/server/src/workspace/WorkspaceEntries.ts` (directory browse)
 * and `WorkspaceFileSystem.ts` (bounded, containment-guarded file read) (MIT),
 * re-expressed in this package's idioms — the terminal/diff/editor pattern:
 * requests ride `RpcClientFrame`; replies get their own frame kinds (see
 * rpc.ts) so `ClientMessage`/`ServerMessage` stay parity-pinned.
 *
 * Design notes:
 *   - Both ops target the SESSION's project (worktree-aware `meta.cwd`,
 *     resolved server-side, never the wire). `path` is repo-RELATIVE (the diff
 *     set's forward-slash shape); the server resolves it INSIDE the cwd with
 *     the SAME containment gate as editorLauncher (relative-only, segment-aware
 *     `..`, symlink-realpath compare) — traversal outside the project is
 *     rejected. See apps/server/src/pathContainment.ts.
 *   - `file_list` browses ONE directory (lazy tree expansion); the root is the
 *     project cwd (omit `path`). Entries are bounded at
 *     {@link FILE_LIST_MAX_ENTRIES} with a `truncated` flag. It does NOT apply
 *     `.gitignore` — like the donor's directory browse (its recursive search
 *     index, which ripgrep-filters by gitignore, is a separate surface not
 *     ported here). Symlinked entries are omitted (the donor never follows
 *     links out of the project).
 *   - `file_read` is on-demand and bounded: text is capped at
 *     {@link FILE_READ_MAX_BYTES} with a `truncated` flag; a NUL byte in the
 *     read prefix flags the file `binary` (empty content); a recognised image
 *     extension within {@link FILE_IMAGE_MAX_BYTES} is returned as a `data:`
 *     URI (`content`), else it degrades to `binary`. No caching (the donor's
 *     read is on-demand too).
 */

/** Cap (in bytes) of a text file's content read into memory / onto the wire. */
export const FILE_READ_MAX_BYTES = 1_048_576;
/** Cap (in bytes) of an image returned inline as a `data:` URI (else binary). */
export const FILE_IMAGE_MAX_BYTES = 2_097_152;
/**
 * Cap (in characters) of the `content` field on the wire. Covers both a text
 * read (≤ FILE_READ_MAX_BYTES chars, since UTF-8 → UTF-16 never expands the
 * unit count) and an image data URI (base64 of FILE_IMAGE_MAX_BYTES ≈
 * 2_796_204 chars + the `data:<mime>;base64,` header), with headroom.
 */
export const FILE_CONTENT_MAX_CHARS = 3_000_000;
/** Cap on the number of entries returned for one directory listing. */
export const FILE_LIST_MAX_ENTRIES = 2_000;

/** Integer with `Number.isInteger` semantics (`WireInt` parity — see diff.ts). */
const wireInt = (description: string) =>
  Schema.Number.pipe(
    Schema.filter((n) => (Number.isInteger(n) && n >= 0) || "must be a non-negative integer", {
      identifier: "FileWireInt",
      description,
    }),
  );

/** A relative directory path, or "" for the project root (the returned form). */
export const FileDirPath = Schema.String.pipe(Schema.maxLength(4_096));
export type FileDirPath = typeof FileDirPath.Type;

/** One entry in a directory listing: a file or a subdirectory. */
export const FileEntryKind = Schema.Literal("file", "dir");
export type FileEntryKind = typeof FileEntryKind.Type;

/** One directory entry — a bare name (not a path), its kind, and, for files,
 * their byte size (null for directories). */
export const FileListEntry = Schema.Struct({
  name: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(512)),
  kind: FileEntryKind,
  /** File size in bytes; null for directories. */
  size: Schema.NullOr(wireInt("file size in bytes")),
});
export type FileListEntry = typeof FileListEntry.Type;

/**
 * How a file's content is delivered:
 *   - `text`:   `content` is the UTF-8 text (bounded; see `truncated`).
 *   - `image`:  `content` is a `data:<mime>;base64,…` URI for the whole file.
 *   - `binary`: not text and not a previewable image; `content` is empty.
 */
export const FileContentKind = Schema.Literal("text", "image", "binary");
export type FileContentKind = typeof FileContentKind.Type;

// ---------------------------------------------------------------------------
// Client → server file requests (ride RpcClientFrame alongside ClientMessage)
// ---------------------------------------------------------------------------

export const FileClientRequest = Schema.Union(
  Schema.Struct({
    /** List one directory within the session's project (omit `path` = root). */
    type: Schema.Literal("file_list"),
    sessionId: Schema.String,
    /** Repo-relative directory; resolved INSIDE the session cwd server-side. */
    path: Schema.optional(DiffPath),
  }),
  Schema.Struct({
    /** Read one file of the session's project, bounded (see the caps above). */
    type: Schema.Literal("file_read"),
    sessionId: Schema.String,
    /** Repo-relative file path; resolved INSIDE the session cwd server-side. */
    path: DiffPath,
  }),
);
export type FileClientRequest = typeof FileClientRequest.Type;
