import { copyFile, mkdir, rm, stat } from "node:fs/promises";
import path from "node:path";
import { CHECKPOINT_LABEL_MAX_CHARS, CHECKPOINT_MAX_RETAINED } from "@agent-deck/contracts";
import type { CheckpointInfo } from "@agent-deck/contracts";
import { Effect } from "effect";
import { gitCaptureCheckpoint, gitDeleteRefs, isGitRepo } from "../git.ts";
import { makeKeyedJsonStoreHandle } from "./persistence.ts";

/**
 * Checkpoint capture service (Slice 18a — CAPTURE + list, SERVER-ONLY). At each
 * idle turn-boundary this snapshots the just-finished turn as the pair fixed by
 * docs/checkpoints-design.md:
 *
 *   1. CONVERSATION — pi's session file, copied WHOLESALE (never parsed) to
 *      `<dataDir>/checkpoints/<sessionId>/<n>.session`. This is the same opaque
 *      copy `SessionManager.fork()` does (`copyFileSync`) — pi's format can
 *      change and we stay correct.
 *   2. WORKSPACE — the working tree of `checkpointCwd` (`meta.worktreePath ??
 *      meta.cwd`), captured as a HIDDEN git ref
 *      `refs/agent-deck/checkpoints/<sessionId>/<n>` via the temp-index
 *      tree-capture in ../git.ts (which never touches the user's real index or
 *      working tree). A NON-GIT cwd skips this half — the checkpoint then
 *      carries only the conversation snapshot (`hasFiles: false`).
 *
 * Capture is INERT until Slice 18b restores; landing it alone is safe.
 *
 * ## Storage decision (no SQLite — design doc §"Storage decision")
 *
 * The heavy state lives where it belongs: conversation snapshots are files under
 * `<dataDir>/checkpoints/`, workspace state is git refs (git's object store), and
 * only the light per-session metadata index — a bounded list per session — is
 * JSON, kept via the keyed store in ./persistence.ts (atomic tmp + rename, the
 * same byte discipline as sessions.json). SQLite (the S6 deferred follow-up) is
 * NOT required at this volume and is deliberately avoided; revisit only if
 * checkpoint metadata queries ever become a bottleneck (they won't).
 *
 * ## Config-bound, so built at the composition root (not a runtime layer)
 *
 * Unlike the SessionDiff service, a checkpoint store is bound to the server's
 * `dataDir` (not a runtime concern), so — like the `SessionIndex` class facade —
 * it is constructed directly in server.ts with its data dir rather than resolved
 * through the ManagedRuntime. Its git + fs work is one-shot async (../git.ts is
 * plain async too), so the surface is promise-based; the JSON store handle it
 * owns is context-free and built with a total `Effect.runSync(make*)`, exactly
 * as persistence.ts documents for its synchronous facade.
 *
 * ## Never perturb the turn (async fs on the capture path)
 *
 * Capture is forked fire-and-forget off the idle boundary, but a forked Effect
 * fiber still shares the ONE event loop — a synchronous `copyFileSync` of a large
 * session file would stall pi stdio + WebSocket delivery for its duration. So the
 * snapshot copy, stat, mkdir and prune all use async `fs/promises`, and the git
 * capture is async too: nothing here blocks the loop, so receipt/turn timing (the
 * e2e suite's synchronization point) is undisturbed. Only the tiny metadata-index
 * flush is synchronous, matching persistence.ts's atomic-write convention.
 */

/** The hidden-ref namespace for workspace checkpoints (never under refs/heads,
 * so `git branch` stays clean). */
const CHECKPOINT_REF_PREFIX = "refs/agent-deck/checkpoints";

/** One captured checkpoint's on-disk record (server-internal — the wire only
 * ever sees the {@link CheckpointInfo} projection). */
export interface CheckpointRecord {
  /** Monotonic per-session capture index (0-based, in capture order). */
  readonly turnIndex: number;
  readonly createdAt: string;
  /** Short human label — the turn's first user message, bounded. */
  readonly label: string;
  /** Absolute path of the wholesale session-file copy. */
  readonly sessionSnapshotPath: string;
  /** The hidden workspace ref, or null for a non-git (or git-failed) capture. */
  readonly gitRef: string | null;
  /** The checkpoint cwd (worktree-aware), for restoring/pruning its ref. */
  readonly cwd: string;
  /** True when the workspace half (the git ref) was captured. */
  readonly hasFiles: boolean;
  /** The source session file's size at capture — dedup identity (see capture). */
  readonly sourceSize: number;
  /** The source session file's mtime at capture — dedup identity. */
  readonly sourceMtimeMs: number;
}

export interface CheckpointCaptureInput {
  readonly sessionId: string;
  /** `meta.worktreePath ?? meta.cwd` — resolved server-side by the caller. */
  readonly cwd: string;
  /** `meta.piSessionFile` — the conversation half's source (undefined → skip). */
  readonly sessionFile: string | undefined;
  /** The turn's first user message (bounded + first-lined here). */
  readonly label: string;
}

export interface CheckpointServiceShape {
  /**
   * Capture a checkpoint of the just-finished turn. Best-effort and idempotent
   * per turn: returns the new record, or `null` when nothing was captured (no
   * session file yet, the source vanished, or the session file is unchanged
   * since the last checkpoint — a second idle for the same turn). Never throws.
   */
  readonly capture: (input: CheckpointCaptureInput) => Promise<CheckpointRecord | null>;
  /** A session's checkpoints as the client sees them (oldest capture first). */
  readonly list: (sessionId: string) => Promise<CheckpointInfo[]>;
  /** A session's raw records (server-internal — rollback/tests). */
  readonly records: (sessionId: string) => Promise<CheckpointRecord[]>;
}

export interface CheckpointServiceOptions {
  readonly dataDir: string;
  /** Retention cap per session (tests); defaults to CHECKPOINT_MAX_RETAINED. */
  readonly maxPerSession?: number;
}

const refFor = (sessionId: string, turnIndex: number): string =>
  `${CHECKPOINT_REF_PREFIX}/${sessionId}/${turnIndex}`;

/** First line, trimmed, bounded — the human label a turn's user message becomes. */
const toLabel = (raw: string): string => {
  const firstLine = raw.split("\n", 1)[0]?.trim() ?? "";
  return firstLine.length > CHECKPOINT_LABEL_MAX_CHARS
    ? `${firstLine.slice(0, CHECKPOINT_LABEL_MAX_CHARS - 1)}…`
    : firstLine;
};

const toInfo = (record: CheckpointRecord): CheckpointInfo => ({
  turnIndex: record.turnIndex,
  createdAt: record.createdAt,
  label: record.label,
  hasFiles: record.hasFiles,
});

export const makeCheckpointService = (
  options: CheckpointServiceOptions,
): CheckpointServiceShape => {
  const cap = options.maxPerSession ?? CHECKPOINT_MAX_RETAINED;
  const checkpointsRoot = path.join(options.dataDir, "checkpoints");
  // Context-free store handle — a total Effect.runSync build, as persistence.ts
  // documents for its synchronous facade.
  const store = Effect.runSync(
    makeKeyedJsonStoreHandle<CheckpointRecord>(options.dataDir, ["checkpoints", "index.json"]),
  );
  const getRecords = (sessionId: string): CheckpointRecord[] =>
    Effect.runSync(store.get(sessionId));
  const setRecords = (sessionId: string, records: CheckpointRecord[]): void =>
    Effect.runSync(store.set(sessionId, records));

  // Per-session serialization: idle-boundary captures are forked fibers, so two
  // could overlap across the git-capture await and race the read-modify-write of
  // the index (duplicate turnIndex / clobbered list). Chain them per session.
  const chains = new Map<string, Promise<unknown>>();
  const serialize = <T>(sessionId: string, fn: () => Promise<T>): Promise<T> => {
    const prev = chains.get(sessionId) ?? Promise.resolve();
    const next = prev.then(fn, fn);
    chains.set(
      sessionId,
      next.then(
        () => {},
        () => {},
      ),
    );
    return next;
  };

  const captureNow = async (input: CheckpointCaptureInput): Promise<CheckpointRecord | null> => {
    // No conversation half → no checkpoint (rollback needs the session file).
    if (!input.sessionFile) return null;
    let sourceStat: { size: number; mtimeMs: number };
    try {
      const s = await stat(input.sessionFile);
      sourceStat = { size: s.size, mtimeMs: s.mtimeMs };
    } catch {
      return null; // the session file vanished mid-idle — skip this checkpoint
    }

    const existing = getRecords(input.sessionId);
    const last = existing[existing.length - 1];
    // Dedup: an idle that fires again for the SAME turn sees an unchanged
    // session file (pi appends per turn) — don't capture a duplicate.
    if (last && last.sourceSize === sourceStat.size && last.sourceMtimeMs === sourceStat.mtimeMs) {
      return null;
    }
    const turnIndex = last ? last.turnIndex + 1 : 0;

    // 1. Conversation half — wholesale COPY of the session file (never parsed).
    const sessionDir = path.join(checkpointsRoot, input.sessionId);
    const sessionSnapshotPath = path.join(sessionDir, `${turnIndex}.session`);
    try {
      await mkdir(sessionDir, { recursive: true });
      await copyFile(input.sessionFile, sessionSnapshotPath);
    } catch {
      return null; // couldn't snapshot the conversation — no half-checkpoint
    }

    // 2. Workspace half — a hidden git ref of the worktree (best-effort). A
    // non-git cwd or a git failure degrades to conversation-only (hasFiles:false).
    let gitRef: string | null = null;
    try {
      if (await isGitRepo(input.cwd)) {
        const ref = refFor(input.sessionId, turnIndex);
        await gitCaptureCheckpoint(input.cwd, ref);
        gitRef = ref;
      }
    } catch {
      gitRef = null;
    }

    const record: CheckpointRecord = {
      turnIndex,
      createdAt: new Date().toISOString(),
      label: toLabel(input.label),
      sessionSnapshotPath,
      gitRef,
      cwd: input.cwd,
      hasFiles: gitRef !== null,
      sourceSize: sourceStat.size,
      sourceMtimeMs: sourceStat.mtimeMs,
    };

    // Append + prune oldest beyond the cap. Crash-safe ordering: flush the
    // trimmed INDEX FIRST so metadata only ever references live data, THEN
    // delete the pruned durable state (snapshot files + git refs). A crash in
    // the delete window then leaves harmless orphan files/refs — never index
    // records pointing at missing snapshots (which S18b rollback would resolve
    // to a broken restore). The reverse order seeds exactly those dangling refs.
    const next = [...existing, record];
    const overflow = next.length - cap;
    const removed = overflow > 0 ? next.splice(0, overflow) : [];
    setRecords(input.sessionId, next);
    if (removed.length > 0) {
      const refsByCwd = new Map<string, string[]>();
      for (const gone of removed) {
        await rm(gone.sessionSnapshotPath, { force: true }).catch(() => {});
        if (gone.gitRef) {
          const list = refsByCwd.get(gone.cwd) ?? [];
          list.push(gone.gitRef);
          refsByCwd.set(gone.cwd, list);
        }
      }
      for (const [cwd, refs] of refsByCwd) {
        await gitDeleteRefs(cwd, refs).catch(() => {});
      }
    }
    return record;
  };

  return {
    capture: (input) => serialize(input.sessionId, () => captureNow(input)).catch(() => null),
    list: (sessionId) => serialize(sessionId, async () => getRecords(sessionId).map(toInfo)),
    records: (sessionId) => serialize(sessionId, async () => getRecords(sessionId)),
  };
};
