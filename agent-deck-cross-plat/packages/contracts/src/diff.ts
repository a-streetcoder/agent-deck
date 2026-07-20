import { Schema } from "effect";

/**
 * Diff-engine wire contract (Slice 9) — per-turn changed-file tracking and
 * on-demand unified diffs for a session's working tree. Shaped from t3code's
 * `apps/server/src/vcs/GitVcsDriverCore.ts` review-diff surface (MIT):
 * working-tree-vs-HEAD base, untracked-file synthesis, bounded patch output
 * with an explicit truncation flag — re-expressed in this package's idioms
 * (the terminal.ts pattern: requests ride `RpcClientFrame`, replies/pushes get
 * their own frame kinds so `ClientMessage`/`ServerMessage` stay parity-pinned).
 *
 * Design notes:
 *   - The diff base is the working tree vs HEAD for the SESSION's checkout
 *     (worktree-aware `meta.cwd`) — a worktree session naturally scopes to its
 *     own branch. Renames are detected (`-M`); untracked files are included
 *     (status `"?"`) with diffs synthesized against `/dev/null`, exactly like
 *     the donor's `readUntrackedReviewDiffs`.
 *   - Every size is bounded: the changed-file SET is capped at
 *     {@link DIFF_MAX_FILES} entries and each file's patch at
 *     {@link DIFF_MAX_PATCH_CHARS} characters, both with `truncated` flags.
 *   - `diff_changed` is pushed after a turn boundary (session idle) when the
 *     refreshed set differs from the previous one, carrying the new set so
 *     the Slice 10 panel needs no follow-up round trip.
 */

/** Cap (in characters) of one file's unified diff on the wire. */
export const DIFF_MAX_PATCH_CHARS = 200_000;
/** Cap on the number of entries in one changed-file set. */
export const DIFF_MAX_FILES = 500;

/** Integer with `Number.isInteger` semantics (`WireInt` parity — see protocol.ts). */
const wireInt = (description: string) =>
  Schema.Number.pipe(
    Schema.filter((n) => Number.isInteger(n) || "must be an integer", {
      identifier: "DiffWireInt",
      description,
    }),
  );

/** A repo-relative path as git reports it (forward slashes), bounded. */
export const DiffPath = Schema.String.pipe(Schema.minLength(1), Schema.maxLength(4_096));
export type DiffPath = typeof DiffPath.Type;

/**
 * One-letter change status, following `git diff --name-status` plus `"?"` for
 * untracked: Added, Modified, Deleted, Renamed, Copied, Type-change, Unmerged.
 */
export const DiffFileStatus = Schema.Literal("A", "M", "D", "R", "C", "T", "U", "?");
export type DiffFileStatus = typeof DiffFileStatus.Type;

/** One changed file in a session's working tree, with per-file add/del stats. */
export const DiffFileEntry = Schema.Struct({
  path: DiffPath,
  /** The rename/copy source (present only when status is `R`/`C`). */
  oldPath: Schema.optional(DiffPath),
  status: DiffFileStatus,
  /** Lines added; null for binary files (numstat `-`). */
  insertions: Schema.NullOr(wireInt("lines added")),
  /** Lines removed; null for binary files (numstat `-`). */
  deletions: Schema.NullOr(wireInt("lines removed")),
  binary: Schema.Boolean,
});
export type DiffFileEntry = typeof DiffFileEntry.Type;

// ---------------------------------------------------------------------------
// Client → server diff requests (ride RpcClientFrame alongside ClientMessage)
// ---------------------------------------------------------------------------

export const DiffClientRequest = Schema.Union(
  Schema.Struct({
    /** List the session's changed files (served from the per-session cache). */
    type: Schema.Literal("diff_files"),
    sessionId: Schema.String,
  }),
  Schema.Struct({
    /** Fetch one file's unified diff (bounded — see DIFF_MAX_PATCH_CHARS). */
    type: Schema.Literal("diff_file"),
    sessionId: Schema.String,
    /** Must be a path from the session's changed-file set (verbatim). */
    path: DiffPath,
  }),
);
export type DiffClientRequest = typeof DiffClientRequest.Type;

// ---------------------------------------------------------------------------
// Server → client push (rides the `diff_push` frame)
// ---------------------------------------------------------------------------

/**
 * Pushed when a session's changed-file set was refreshed at a turn boundary
 * AND differs from the previous set. Carries the full new set (bounded).
 */
export const DiffPush = Schema.Struct({
  type: Schema.Literal("diff_changed"),
  sessionId: Schema.String,
  /** False when the session's cwd is not inside a git work tree. */
  repo: Schema.Boolean,
  files: Schema.Array(DiffFileEntry).pipe(Schema.maxItems(DIFF_MAX_FILES)),
  /** True when the set was capped at DIFF_MAX_FILES entries. */
  truncated: Schema.Boolean,
});
export type DiffPush = typeof DiffPush.Type;
