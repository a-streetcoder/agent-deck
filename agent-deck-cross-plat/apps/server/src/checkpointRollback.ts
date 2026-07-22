import { copyFileSync } from "node:fs";
import type { SessionMeta } from "@agent-deck/contracts";
import { gitRestoreCheckpoint } from "./git.ts";
import type { ReceiptBus } from "./receipts.ts";
import type { ManagedSession, SessionManager } from "./SessionManager.ts";
import type { CheckpointServiceShape } from "./services/checkpoints.ts";

/**
 * Checkpoint rollback orchestrator (Slice 18b) — rolls a live session back to a
 * prior turn, restoring BOTH halves and relaunching pi. It sits ABOVE the two
 * lower services it coordinates:
 *
 *   - {@link CheckpointServiceShape.prepareRollback} owns the metadata step: a
 *     FORCED safety checkpoint of the pre-rollback state + the list truncation
 *     (so the rollback is itself undoable — design §"Rollback" step 5).
 *   - {@link SessionManager} owns the session lifecycle: `destroy` (stop pi) then
 *     `reopen` (relaunch through the EXACT resume() path — resumeSessionPath +
 *     seedFromHistory + restorePlan + startIngestion), reused verbatim, not
 *     reinvented.
 *
 * ## Order (consistency — design §"Risks/invariants")
 *
 * All of these steps run inside ONE per-session serialized critical section: the
 * physical restore is handed to {@link CheckpointServiceShape.prepareRollback} as
 * a `restore` callback that executes under the SAME lock that guards capture, so
 * no forked idle-boundary capture fiber can interleave and snapshot a
 * half-restored worktree / mismatched conversation. The steps run so that ANY
 * failure leaves the session STOPPABLE and re-openable, never a
 * conversation-restored-but-files-not (or vice-versa) half-state:
 *
 *   1. Metadata: safety checkpoint + truncate. Reads the CURRENT session file +
 *      worktree while pi is still idle (both flushed at the turn boundary), so a
 *      throw here mutates nothing — the session stays live.
 *   2. Stop pi (`destroy`). After this the worktree + session file are quiescent,
 *      so the file restore can't race pi and (on Windows) no open handle blocks
 *      `git clean`.
 *   3. Restore the workspace: `git restore` the worktree to the target's hidden
 *      ref. A non-git target (no ref) legitimately skips this and reports
 *      `filesRestored:false` (conversation-only). But a target that HAS a ref and
 *      FAILS to restore (missing ref / git error) ABORTS the rollback rather than
 *      creating a files-old/conversation-new half-state: it relaunches from the
 *      ORIGINAL session file (both halves stay at pre-rollback) and rejects with
 *      a clear error — the safety checkpoint is the recovery point.
 *   4. Restore the conversation: copy the target snapshot back over the live pi
 *      session file (the `fork()` primitive — a wholesale copy, never parsed).
 *   5. Relaunch pi via `reopen` (resume()). resume() tears down a half-built
 *      session on its own seed failure, so even a relaunch failure leaves the
 *      session re-openable from the sidebar rather than orphaning a dead pi.
 *   6. Emit the `checkpoint_rolled_back` receipt so tests/UI synchronize.
 */

export interface CheckpointRollbackDeps {
  readonly sessions: SessionManager;
  readonly checkpoints: CheckpointServiceShape;
  readonly receipts: ReceiptBus;
  /**
   * Relaunch an ended session through the resume() path. server.ts wires this
   * identically to the POST /sessions/:id/resume route (its env + fallback
   * launch plan), so rollback reuses the one correct relaunch, not a copy.
   */
  readonly reopen: (meta: SessionMeta) => Promise<ManagedSession>;
}

export interface CheckpointRollbackResult {
  /** True when the target's workspace was restored. False ONLY for a by-design
   * non-git checkpoint (no ref) — conversation restored, files unchanged. A
   * target that HAS a ref but fails to restore does not return false; it ABORTS
   * the whole rollback (throws) rather than leaving a half-state. */
  readonly filesRestored: boolean;
}

export interface CheckpointRollbackGateway {
  rollback(params: { sessionId: string; turnIndex: number }): Promise<CheckpointRollbackResult>;
}

export function makeCheckpointRollback(deps: CheckpointRollbackDeps): CheckpointRollbackGateway {
  const { sessions, checkpoints, receipts, reopen } = deps;

  return {
    async rollback({ sessionId, turnIndex }) {
      const session = sessions.get(sessionId);
      if (!session) throw new Error("unknown session");
      const meta = session.meta;
      if (!meta.piSessionFile) {
        throw new Error("this session has no conversation to roll back to");
      }
      const cwd = meta.worktreePath ?? meta.cwd;
      const sessionFile = meta.piSessionFile;

      // The metadata step (1) AND the physical restore (2-6) run as ONE
      // per-session serialized critical section: the `restore` callback executes
      // INSIDE the same lock that guards checkpoint capture. A forked
      // idle-boundary capture fiber shares that per-session chain, so were the
      // restore to run after prepareRollback resolved (outside the lock), a
      // capture enqueuing mid-restore could snapshot a half-restored worktree /
      // pre-rollback conversation as a spurious, internally-inconsistent newest
      // checkpoint. Holding the lock across the restore forces any such capture
      // to run strictly after, against the fully-restored consistent state.
      let filesRestored = false;

      // 1. Metadata: capture a safety checkpoint of the CURRENT state (undo
      // point) and truncate the future. Throws if turnIndex is unknown — before
      // anything is stopped or mutated, so the session stays live.
      await checkpoints.prepareRollback(
        {
          sessionId,
          cwd,
          sessionFile,
          label: meta.title ? `Before rollback — ${meta.title}` : "Before rollback",
          turnIndex,
        },
        async ({ target }) => {
          // 2. Stop the live session (kills pi cleanly). From here the session
          // is out of the manager; the reopen below brings it back.
          await sessions.destroy(sessionId);

          // 3. Restore the workspace (only when the checkpoint captured one).
          // A target that HAS a gitRef but does NOT restore (missing ref, or a
          // git error mid-restore) is a FAILURE, not a by-design non-git
          // rollback — and proceeding to restore the conversation would create
          // the files-old / conversation-new half-state the design forbids
          // (§"Risks/invariants": surface a clear error, never a half-state).
          // So on failure we ABORT: leave the conversation at pre-rollback by
          // relaunching from the ORIGINAL session file (NOT the target
          // snapshot), keeping both halves consistent, and reject. The safety
          // checkpoint captured in step 1 is the recovery point. A non-git
          // target (no gitRef) legitimately restores conversation only.
          if (target.gitRef) {
            let restored = false;
            let gitError: unknown = null;
            try {
              restored = await gitRestoreCheckpoint(target.cwd, target.gitRef);
            } catch (error) {
              gitError = error;
            }
            if (!restored) {
              await reopen({ ...meta, endedAt: undefined });
              throw new Error(
                gitError
                  ? "Couldn't restore this checkpoint's files (git error) — rollback aborted; the conversation is unchanged and a safety checkpoint was saved."
                  : "This checkpoint's file snapshot is missing — rollback aborted; the conversation is unchanged.",
              );
            }
            filesRestored = true;
          }

          // 4. Restore the conversation: the target snapshot back over the live
          // pi session file (wholesale copy, exactly like fork()). Reached only
          // when files restored OK, or the target is a non-git checkpoint.
          copyFileSync(target.sessionSnapshotPath, sessionFile);

          // 5. Relaunch pi through resume() (resumeSessionPath = the restored
          // file → seedFromHistory rebuilds the transcript as of the target
          // turn).
          await reopen({ ...meta, endedAt: undefined });

          // 6. Synchronization point for the UI + e2e.
          receipts.emit("checkpoint_rolled_back", sessionId);
        },
      );
      return { filesRestored };
    },
  };
}
