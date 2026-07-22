import { copyFile, mkdir, rm, stat } from "node:fs/promises";
import path from "node:path";
import { CHECKPOINT_LABEL_MAX_CHARS, CHECKPOINT_MAX_RETAINED } from "@agent-deck/contracts";
import type { CheckpointInfo } from "@agent-deck/contracts";
import { Effect } from "effect";
import { gitCaptureCheckpoint, gitDeleteRefs, isGitRepo } from "../git.ts";
import { makeKeyedJsonStoreHandle } from "./persistence.ts";

/**
 * Slice 18b (rollback) extends this service beyond capture with the metadata
 * side of a rollback: the FORCED safety checkpoint of the pre-rollback state
 * plus the list truncation. See `prepareRollback` below and
 * docs/checkpoints-design.md §"Rollback". The workspace + conversation restore
 * and the pi relaunch are NOT here — they live in ../checkpointRollback.ts,
 * which orchestrates SessionManager (stop + resume) around this metadata step.
 */

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

/** The result of {@link CheckpointServiceShape.prepareRollback}: the target
 * record the caller restores TO, and the forced safety checkpoint of the
 * pre-rollback state (null only when the current conversation couldn't be
 * snapshotted — then the rollback is not undoable). */
export interface CheckpointRollbackPrep {
  readonly target: CheckpointRecord;
  readonly safety: CheckpointRecord | null;
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
  /**
   * Slice 18b — the metadata step of a rollback to `input.turnIndex`, run as one
   * per-session-serialized critical section so no concurrent capture can race
   * the read-modify-write:
   *
   *   1. FORCED safety checkpoint of the CURRENT state (`input.sessionFile` +
   *      `input.cwd`), bypassing the per-turn dedup so the pre-rollback state is
   *      ALWAYS preserved as the newest checkpoint — even at idle, where the
   *      workspace is byte-identical to the last capture (the common case). This
   *      is what makes the rollback itself undoable.
   *   2. Truncate the list to `[turnIndex <= target] + [the safety checkpoint]`:
   *      the future (target < turnIndex <= old tip) is gone, but the safety
   *      checkpoint survives as the new tip (design §"Rollback" step 5, the
   *      documented "simplest" model). The dropped snapshots + git refs are
   *      deleted crash-safely (trimmed index flushed FIRST, then durable state),
   *      exactly as capture()'s prune does.
   *   3. If a `restore` callback is supplied, it runs INSIDE this same critical
   *      section, after the metadata step and before the lock releases. The
   *      orchestrator's physical restore (stop pi → git-restore the worktree →
   *      copy the conversation snapshot back → relaunch) MUST run here, not after
   *      `prepareRollback` resolves: a forked idle-boundary capture fiber shares
   *      the per-session serialize chain, so restoring outside the lock lets a
   *      capture that enqueues mid-restore snapshot a half-restored worktree /
   *      pre-rollback conversation as a spurious, internally-inconsistent newest
   *      checkpoint. Holding the lock across the restore forces any such capture
   *      to run strictly after, against the fully-restored consistent state.
   *
   * Returns the TARGET record (so the callback / caller can `git`-restore its ref
   * + copy its session snapshot back). Rejects when `turnIndex` is unknown, or
   * with whatever the `restore` callback throws (the metadata step has already
   * committed by then — pointing at the target — so the session stays
   * re-openable). WITHOUT a `restore` callback it touches neither the workspace
   * nor the live session file.
   */
  readonly prepareRollback: (
    input: CheckpointCaptureInput & { readonly turnIndex: number },
    restore?: (prep: CheckpointRollbackPrep) => Promise<void>,
  ) => Promise<CheckpointRollbackPrep>;
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

  /**
   * The two-half capture core: snapshot the session file + capture the worktree
   * git ref, building a {@link CheckpointRecord} at `turnIndex`. Returns null
   * only when the CONVERSATION half is unavailable (no/vanished session file, or
   * the snapshot copy failed) — the git half degrades to `hasFiles:false`. Does
   * NOT read or mutate the index; the caller owns append + prune/truncate.
   */
  const buildCheckpoint = async (
    input: CheckpointCaptureInput,
    turnIndex: number,
    sourceStat: { size: number; mtimeMs: number },
  ): Promise<CheckpointRecord | null> => {
    // 1. Conversation half — wholesale COPY of the session file (never parsed).
    const sessionDir = path.join(checkpointsRoot, input.sessionId);
    const sessionSnapshotPath = path.join(sessionDir, `${turnIndex}.session`);
    try {
      await mkdir(sessionDir, { recursive: true });
      await copyFile(input.sessionFile!, sessionSnapshotPath);
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

    return {
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
  };

  /** Delete a set of pruned/dropped records' durable state (snapshot files +
   * hidden git refs), best-effort. The index must already be flushed WITHOUT
   * these records (crash-safe order — see capture/prepareRollback). */
  const deleteDurableState = async (removed: readonly CheckpointRecord[]): Promise<void> => {
    if (removed.length === 0) return;
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
    const record = await buildCheckpoint(input, turnIndex, sourceStat);
    if (record === null) return null;

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
    await deleteDurableState(removed);
    return record;
  };

  const prepareRollbackNow = async (
    input: CheckpointCaptureInput & { turnIndex: number },
  ): Promise<CheckpointRollbackPrep> => {
    const existing = getRecords(input.sessionId);
    const target = existing.find((r) => r.turnIndex === input.turnIndex);
    if (!target) throw new Error(`unknown checkpoint turn ${input.turnIndex}`);

    // 1. FORCED safety checkpoint of the CURRENT state (bypass the per-turn
    // dedup): at idle the workspace equals the last capture, so a dedup'd
    // capture would return null and leave no distinct undo point. The forced
    // snapshot guarantees the pre-rollback state survives as the newest
    // checkpoint. Null only when the conversation half is unavailable.
    let safety: CheckpointRecord | null = null;
    if (input.sessionFile) {
      try {
        const s = await stat(input.sessionFile);
        const last = existing[existing.length - 1];
        const safetyTurn = last ? last.turnIndex + 1 : 0;
        safety = await buildCheckpoint(input, safetyTurn, { size: s.size, mtimeMs: s.mtimeMs });
      } catch {
        safety = null; // couldn't snapshot the current state — rollback is not undoable
      }
    }

    // 2. Truncate to [turnIndex <= target] + [the safety checkpoint]. The safety
    // record is newer than every existing one (its turnIndex = old tip + 1), so
    // "turnIndex <= target" alone would drop it — keep it explicitly.
    const afterSafety = safety ? [...existing, safety] : existing;
    const safetyTurn = safety?.turnIndex;
    const keep: CheckpointRecord[] = [];
    const drop: CheckpointRecord[] = [];
    for (const r of afterSafety) {
      if (r.turnIndex <= target.turnIndex || r.turnIndex === safetyTurn) keep.push(r);
      else drop.push(r);
    }
    // Crash-safe: flush the trimmed index FIRST, then delete the dropped durable
    // state — a crash then leaves orphan files/refs, never a record pointing at
    // a deleted snapshot (exactly the capture() prune discipline).
    setRecords(input.sessionId, keep);
    await deleteDurableState(drop);
    return { target, safety };
  };

  return {
    capture: (input) => serialize(input.sessionId, () => captureNow(input)).catch(() => null),
    list: (sessionId) => serialize(sessionId, async () => getRecords(sessionId).map(toInfo)),
    records: (sessionId) => serialize(sessionId, async () => getRecords(sessionId)),
    prepareRollback: (input, restore) =>
      serialize(input.sessionId, async () => {
        const prep = await prepareRollbackNow(input);
        // The physical restore (if any) runs INSIDE the lock so no forked
        // capture can snapshot the half-restored worktree/conversation.
        if (restore) await restore(prep);
        return prep;
      }),
  };
};
