import { stat } from "node:fs/promises";
import nodePath from "node:path";
import {
  DIFF_MAX_FILES,
  DIFF_MAX_PATCH_CHARS,
  type DiffFileEntry,
  type DiffFileStatus,
} from "@agent-deck/contracts";
import { Context, Effect, Layer } from "effect";
import {
  gitDiffBase,
  gitDiffFilePatch,
  gitDiffNameStatus,
  gitDiffNumstat,
  gitDiffUntrackedNumstat,
  gitDiffUntrackedPatch,
  gitListUntracked,
  isGitRepo,
} from "../git.ts";

/**
 * SessionDiff as an Effect service (Slice 9) — per-turn changed-file tracking
 * and on-demand diff computation for a session's working tree. Ported from the
 * shapes in t3code's `apps/server/src/vcs/GitVcsDriverCore.ts` +
 * `VcsStatusBroadcaster.ts` (MIT) and re-expressed in this repo's service
 * idioms — services/terminal.ts is the freshest template; this service is
 * simpler (no scoped resources: git runs are one-shot execs via ../git.ts).
 *
 * File anatomy (the pushBus/piHost/terminal template):
 *   1. data types + shape interface (effectful API surface)
 *   2. `makeSessionDiff` — the implementation (per-session cache + git policy)
 *   3. `Context.Tag` service class
 *   4. `SessionDiffLive` Layer — joined into `serverLayers` in ../runtime.ts
 *
 * ## Diff-base semantics (donor's review-diff preview)
 *
 * The working tree vs HEAD for the SESSION's checkout (`meta.cwd`, worktree-
 * aware — a worktree session naturally scopes to its own branch), staged and
 * unstaged changes alike, with rename detection (`-M`). Untracked files are
 * part of the set (status `"?"`) and their diffs are synthesized against
 * `/dev/null`, exactly like the donor's `readUntrackedReviewDiffs`. In a fresh
 * repo with no commits the base falls back to the empty tree (git.ts
 * `gitDiffBase`), so staged files still show as additions.
 *
 * ## Cache + refresh (the VcsStatusBroadcaster fingerprint pattern)
 *
 * Each session's changed-file set is cached; `refresh` recomputes and reports
 * whether the set CHANGED vs the previous one (fingerprint compare over the
 * sorted entries — the donor broadcasts only on fingerprint change). A missing
 * cache entry compares as an empty set, so a session's first refresh in a
 * clean tree (or a non-repo cwd) reports `changed: false` — no spurious push.
 * Refreshes are triggered at TURN BOUNDARIES (session idle) and on demand;
 * nothing here runs per keystroke.
 *
 * ## Non-git sessions (the donor's NON_REPOSITORY guard)
 *
 * A cwd outside any git work tree answers `{ repo: false, files: [] }` — never
 * an error. The repo probe is one `rev-parse` per refresh/list (turn-boundary
 * cadence), and failures of any downstream git run degrade to an empty set
 * rather than failing the effect, mirroring the donor's `orElseSucceed` guards.
 */

// ---------------------------------------------------------------------------
// 1. Data types + shape
// ---------------------------------------------------------------------------

/** A session's changed-file set (the `diff_files_ok` / `diff_changed` payload). */
export interface DiffFileSet {
  /** False when the session's cwd is not inside a git work tree. */
  readonly repo: boolean;
  readonly files: readonly DiffFileEntry[];
  /** True when the set was capped at the max-files bound. */
  readonly truncated: boolean;
}

/** One file's unified diff (the `diff_file_ok` payload). */
export interface FileDiffResult {
  readonly path: string;
  readonly diff: string;
  readonly truncated: boolean;
  readonly binary: boolean;
}

export interface DiffRefreshResult {
  readonly set: DiffFileSet;
  /** True when the set differs from the previously cached one. */
  readonly changed: boolean;
}

export interface SessionDiffShape {
  /** The session's changed-file set — cached; computes on first call. */
  readonly listFiles: (sessionId: string, cwd: string) => Effect.Effect<DiffFileSet>;
  /** Recompute the set now (turn boundary / on demand) and diff vs the cache. */
  readonly refresh: (sessionId: string, cwd: string) => Effect.Effect<DiffRefreshResult>;
  /**
   * One file's unified diff, bounded. `path` must be an entry of the session's
   * changed-file set (this is also the traversal guard: only paths git itself
   * reported are ever handed back to git); anything else answers an empty diff.
   */
  readonly fileDiff: (
    sessionId: string,
    cwd: string,
    path: string,
  ) => Effect.Effect<FileDiffResult>;
  /** Drop a session's cache entry (session ended/destroyed). */
  readonly drop: (sessionId: string) => Effect.Effect<void>;
}

export interface SessionDiffOptions {
  /** Patch cap in characters (tests); defaults to the wire-contract cap. */
  readonly maxPatchChars?: number;
  /** Changed-file-set cap in entries (tests); defaults to the wire cap. */
  readonly maxFiles?: number;
}

const EMPTY_SET: DiffFileSet = { repo: false, files: [], truncated: false };

/** Sortable, comparable identity of a set — the donor's status fingerprint. */
const fingerprint = (set: DiffFileSet): string =>
  JSON.stringify([set.repo, set.truncated, set.files]);

/** A missing cache entry compares as an empty file list (see module doc). */
const emptyFingerprintFor = (repo: boolean): string =>
  fingerprint({ repo, files: [], truncated: false });

// ---------------------------------------------------------------------------
// 2. Implementation
// ---------------------------------------------------------------------------

/** How many untracked-file stat runs may be in flight at once (donor: 4). */
const UNTRACKED_STAT_CONCURRENCY = 4;

/** The cheap phase's output: everything 3 git spawns + fs.stat can tell us. */
interface CheapScan {
  base: string;
  nameStatus: Awaited<ReturnType<typeof gitDiffNameStatus>>;
  numstat: Awaited<ReturnType<typeof gitDiffNumstat>>;
  untrackedSorted: string[];
  /**
   * Change-detection identity WITHOUT per-file git spawns: tracked entries
   * carry their numstat, untracked entries their fs.stat size+mtime (syscalls,
   * not processes — content growth in an untracked file bumps both). Only when
   * THIS differs from the cached scan does the expensive per-file untracked
   * numstat pass run (the donor's fingerprint-then-stat-on-demand cadence:
   * VcsStatusBroadcaster fingerprints porcelain output; per-file --no-index
   * reads live only in its on-demand review path).
   */
  fingerprint: string;
  /**
   * Git's "racily clean" hazard, ours too: a same-size rewrite within one
   * mtime tick is invisible to the identity above. True when any untracked
   * file was modified within the last RACY_MTIME_WINDOW_MS — the short-circuit
   * must not trust the fingerprint then (turn-boundary cadence means steady
   * state is far outside the window; only rapid writes force a recompute).
   */
  racy: boolean;
}

const RACY_MTIME_WINDOW_MS = 2_000;

async function cheapScan(cwd: string): Promise<CheapScan | null> {
  if (!(await isGitRepo(cwd))) return null;
  const base = await gitDiffBase(cwd);
  const [nameStatus, numstat, untracked] = await Promise.all([
    gitDiffNameStatus(cwd, base),
    gitDiffNumstat(cwd, base),
    gitListUntracked(cwd),
  ]);
  const untrackedSorted = [...untracked].sort((a, b) => a.localeCompare(b));
  const untrackedIdentity = await mapWithConcurrency(
    untrackedSorted,
    UNTRACKED_STAT_CONCURRENCY,
    async (path) => {
      try {
        const s = await stat(nodePath.join(cwd, path));
        return [path, s.size, s.mtimeMs] as const;
      } catch {
        return [path, -1, -1] as const; // vanished mid-scan
      }
    },
  );
  const now = Date.now();
  const racy = untrackedIdentity.some(([, , mtimeMs]) => now - mtimeMs < RACY_MTIME_WINDOW_MS);
  return {
    base,
    nameStatus,
    numstat,
    untrackedSorted,
    fingerprint: JSON.stringify([base, nameStatus, numstat, untrackedIdentity]),
    racy,
  };
}

/** The expensive phase: assemble the full set, incl. per-file untracked stats. */
async function assembleFileSet(
  cwd: string,
  scan: CheapScan,
  maxFiles: number,
): Promise<DiffFileSet> {
  // numstat is keyed by "oldPath -> path" for renames and plain path
  // otherwise; name-status uses the same identity, so join on it.
  const statKey = (path: string, oldPath?: string): string =>
    oldPath === undefined ? path : `${oldPath}\0${path}`;
  const stats = new Map<string, { insertions: number | null; deletions: number | null }>();
  for (const entry of scan.numstat) {
    stats.set(statKey(entry.path, entry.oldPath), {
      insertions: entry.insertions,
      deletions: entry.deletions,
    });
  }

  const files: DiffFileEntry[] = [];
  for (const entry of scan.nameStatus) {
    const stat = stats.get(statKey(entry.path, entry.oldPath)) ?? stats.get(entry.path);
    // `stat.insertions` may be NULL (binary) — only a MISSING stat means 0.
    const insertions = stat === undefined ? 0 : stat.insertions;
    const deletions = stat === undefined ? 0 : stat.deletions;
    files.push({
      path: entry.path,
      ...(entry.oldPath !== undefined ? { oldPath: entry.oldPath } : {}),
      status: asStatus(entry.status),
      insertions,
      deletions,
      binary: insertions === null && deletions === null,
    });
  }

  // Untracked entries carry real stats too (synthesized vs /dev/null) —
  // bounded concurrency like the donor's untracked-diff reads, and only for
  // entries that fit under the cap (the rest are cut anyway). This per-file
  // git pass is the EXPENSIVE step the cheap fingerprint gates.
  const budget = Math.max(0, maxFiles - files.length);
  const statted = scan.untrackedSorted.slice(0, budget);
  const untrackedStats = await mapWithConcurrency(
    statted,
    UNTRACKED_STAT_CONCURRENCY,
    async (path) => {
      try {
        return await gitDiffUntrackedNumstat(cwd, path);
      } catch {
        return null; // vanished mid-scan / unreadable — stat stays 0/0
      }
    },
  );
  statted.forEach((path, i) => {
    const stat = untrackedStats[i];
    const insertions = stat === null || stat === undefined ? 0 : stat.insertions;
    const deletions = stat === null || stat === undefined ? 0 : stat.deletions;
    files.push({
      path,
      status: "?",
      insertions,
      deletions,
      binary: insertions === null && deletions === null,
    });
  });

  files.sort((a, b) => a.path.localeCompare(b.path));
  const truncated = files.length > maxFiles || scan.untrackedSorted.length > statted.length;
  return { repo: true, files: files.slice(0, maxFiles), truncated };
}

const asStatus = (letter: string): DiffFileStatus => {
  switch (letter) {
    case "A":
    case "M":
    case "D":
    case "R":
    case "C":
    case "T":
    case "U":
      return letter;
    default:
      return "M"; // unknown porcelain letter — treat as a modification
  }
};

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

export const makeSessionDiff = (options: SessionDiffOptions = {}): SessionDiffShape => {
  const maxPatchChars = options.maxPatchChars ?? DIFF_MAX_PATCH_CHARS;
  const maxFiles = options.maxFiles ?? DIFF_MAX_FILES;

  // Per-session cache: the last computed set + BOTH fingerprints. Only ever
  // touched from the promise continuations below (single-threaded JS; the
  // last completed compute wins on a refresh race, which is benign — the next
  // turn boundary reconciles).
  const cache = new Map<
    string,
    { set: DiffFileSet; fingerprint: string; scanFingerprint: string }
  >();

  const compute = async (sessionId: string, cwd: string): Promise<DiffRefreshResult> => {
    let set: DiffFileSet;
    let scanFingerprint: string;
    try {
      const scan = await cheapScan(cwd);
      if (scan === null) {
        set = EMPTY_SET;
        scanFingerprint = "";
      } else {
        const cached = cache.get(sessionId);
        // Cheap short-circuit (the spawn-storm guard): identical scan
        // fingerprint == identical working tree, so the cached set is current
        // and the per-file untracked numstat pass is skipped entirely. A racy
        // scan (untracked mtime too fresh — see CheapScan.racy) never
        // short-circuits: the fingerprint can't be trusted yet.
        if (cached !== undefined && !scan.racy && cached.scanFingerprint === scan.fingerprint) {
          return { set: cached.set, changed: false };
        }
        set = await assembleFileSet(cwd, scan, maxFiles);
        scanFingerprint = scan.fingerprint;
      }
    } catch {
      // Any git failure mid-computation (repo deleted, index lock, git gone)
      // degrades to "repo with no visible changes" rather than an error.
      set = { repo: true, files: [], truncated: false };
      scanFingerprint = "";
    }
    const next = fingerprint(set);
    const previous = cache.get(sessionId)?.fingerprint ?? emptyFingerprintFor(set.repo);
    cache.set(sessionId, { set, fingerprint: next, scanFingerprint });
    return { set, changed: next !== previous };
  };

  return {
    listFiles: (sessionId, cwd) =>
      Effect.promise(async () => {
        const cached = cache.get(sessionId);
        if (cached) return cached.set;
        return (await compute(sessionId, cwd)).set;
      }),

    refresh: (sessionId, cwd) => Effect.promise(() => compute(sessionId, cwd)),

    fileDiff: (sessionId, cwd, path) =>
      Effect.promise(async () => {
        const cached = cache.get(sessionId);
        const set = cached ? cached.set : (await compute(sessionId, cwd)).set;
        const entry = set.files.find((file) => file.path === path);
        // Not in the set (or a non-repo session): the clean empty answer. This
        // doubles as the path-traversal guard — only paths git itself listed
        // are ever passed back to git as pathspecs.
        if (!entry || !set.repo) return { path, diff: "", truncated: false, binary: false };
        if (entry.binary) return { path, diff: "", truncated: false, binary: true };
        try {
          if (entry.status === "?") {
            const out = await gitDiffUntrackedPatch(cwd, path, maxPatchChars);
            return { path, diff: out.text, truncated: out.truncated, binary: false };
          }
          const base = await gitDiffBase(cwd);
          // A rename needs BOTH paths in the pathspec (see git.ts).
          const paths = entry.oldPath !== undefined ? [entry.oldPath, entry.path] : [entry.path];
          const out = await gitDiffFilePatch(cwd, base, paths, maxPatchChars);
          return { path, diff: out.text, truncated: out.truncated, binary: false };
        } catch {
          return { path, diff: "", truncated: false, binary: false };
        }
      }),

    drop: (sessionId) =>
      Effect.sync(() => {
        cache.delete(sessionId);
      }),
  };
};

// ---------------------------------------------------------------------------
// 3. Service tag + 4. Live layer
// ---------------------------------------------------------------------------

export class SessionDiff extends Context.Tag("agent-deck/server/services/SessionDiff")<
  SessionDiff,
  SessionDiffShape
>() {}

/** `Layer.sync` so each runtime owns a fresh cache (one per server). */
export const SessionDiffLive = Layer.sync(SessionDiff, () => makeSessionDiff());
