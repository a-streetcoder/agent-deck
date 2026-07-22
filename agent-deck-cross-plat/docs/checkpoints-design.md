# Slice 18 — Checkpoints & Rollback: Design

The largest feature slice. Roll a session back to a prior turn, restoring BOTH
the conversation and the files as they were. This doc fixes the architecture so
the implementation workflow builds against a spec, not a guess.

## The core model: two independent halves

A "checkpoint" of turn N is the pair:

1. **Conversation state** — pi's session file at the end of turn N. pi OWNS this
   file; we treat it as an opaque blob. We already copy it wholesale in `fork()`
   (`copyFileSync(sessionFilePath, copyTo)` then relaunch with
   `resumeSessionPath`). A checkpoint SNAPSHOTS it the same way; rollback
   RESTORES the snapshot in place and relaunches. **We never parse or mutate pi's
   session-file content** — snapshot = copy out, restore = copy back. This is the
   load-bearing safety boundary: pi's format can change and we stay correct.

2. **Workspace/file state** — the working tree at the end of turn N. The donor
   (t3code `apps/server/src/checkpointing/CheckpointStore.ts`) captures this as a
   HIDDEN GIT REF: a checkpoint commit stored at `refs/agent-deck/checkpoints/<sessionId>/<n>`
   (not a branch, so it never clutters `git branch`), against the session's cwd
   (worktree-aware — `meta.worktreePath ?? meta.cwd`). Restore = reset the
   working tree to that ref. Diff between checkpoints = `git diff ref_a ref_b`
   (reuse the Slice-9 diff plumbing). This is the donor's exact mechanism and it
   composes with our existing git.ts helpers.

The two halves are captured and restored TOGETHER but stored separately. They
must stay consistent: a rollback applies both, or neither (see failure handling).

## Capture — at the turn boundary

We already have a turn-boundary hook: the session goes idle after each turn, and
Slice 9 (diff refresh) + the title fiber fork off it (`forkIn(sessionScope)`).
Checkpoint capture forks off the SAME idle, AFTER the session-file has been
flushed (pi writes it; `meta.piSessionFile` is the handle):

1. Snapshot the session file → `<dataDir>/checkpoints/<sessionId>/<n>.session`
   (a copy; cheap, bounded by transcript size).
2. Capture the worktree → a git checkpoint ref/commit of `checkpointCwd`
   (add-all into a tree + commit-tree at the hidden ref; the working tree and
   index are NOT disturbed — use `git add -A` into a temp index or
   `git stash create`-style tree capture so the user's staged state is
   untouched). NON-GIT cwd: skip the git half; the checkpoint carries only the
   conversation snapshot (rollback then restores conversation only, flagged).
3. Record checkpoint metadata: `{ turnIndex, createdAt, sessionSnapshotPath,
gitRef | null, cwd }` appended to a per-session checkpoint list.

Capture is best-effort and MUST NOT disturb the turn: it forks (never blocks the
idle receipt — the e2e suite synchronizes on receipt timing), and any failure
logs + skips that checkpoint rather than failing the session. Bound the number
of retained checkpoints per session (e.g. last N) — prune oldest (snapshot file

- git ref) beyond the cap.

## Rollback — restore both halves + relaunch

Roll session to checkpoint N:

1. Stop the live session (scope close — kills pi cleanly, as today).
2. Restore the worktree: `git reset --hard <gitRef>` on `checkpointCwd` (only if
   the checkpoint has a gitRef; else skip, flag "files not restored"). This
   DISCARDS uncommitted work after turn N — the rollback action must confirm
   this in the UI (destructive). Consider capturing a SAFETY checkpoint of the
   current state right before rollback so it's undoable.
3. Restore the conversation: copy `<n>.session` back over `meta.piSessionFile`
   (or relaunch with `resumeSessionPath = <n>.session` copied to the live path —
   mirror `fork()`/`resume()` exactly).
4. Relaunch pi from the restored session file, rebuild the transcript from pi's
   canonical history (`seedFromHistory`), restore the activity plan, start
   ingestion — the exact `resume()` sequence, which is already correct.
5. Truncate the checkpoint list after N (the future is gone) — or keep them for
   redo; v1 truncates.

## Storage decision

Per-session checkpoint metadata → the existing `persistence` service (a
`checkpoints: CheckpointRecord[]` field on the session index entry, or a sibling
JSON keyed by sessionId). Session-file snapshots → files under
`<dataDir>/checkpoints/`. Worktree state → git refs (no DB). **SQLite (the S6
deferred follow-up) is NOT required for v1** — the volume is small (bounded list
per session) and the heavy state lives in git + files, not a table. Revisit
SQLite only if checkpoint metadata queries become a bottleneck (they won't at
this scale). Document this decision in the checkpoint service.

## Contracts / ops surface

`packages/contracts/src/checkpoints.ts`, riding `RpcClientFrame` like the other
op families:

- `checkpoints_list { sessionId } → { checkpoints: CheckpointInfo[] }`
  (turnIndex, createdAt, a short label/first-user-message, hasFiles).
- `checkpoint_rollback { sessionId, turnIndex } → ok` (destructive; the client
  confirms first). Emits a push/receipt when the rollback completes so the UI +
  e2e can synchronize (reuse the receipt pattern).
- `checkpoint_diff { sessionId, fromTurn, toTurn }` — OPTIONAL, reuse the Slice-9
  diff service against the two git refs. Defer to S18b if it complicates S18a.

Ownership validation + cwd-from-session (server-side) exactly like the terminal/
diff/files ops.

## The two-build-phase split

- **S18a — capture + list (server-only, no rollback):** the checkpoint service
  (session-file snapshot + git-ref capture at the idle boundary), persistence of
  checkpoint records, `checkpoints_list` op, pruning/cap. Tests: real scratch git
  repo — run turns (fake pi), assert a checkpoint per turn with a valid git ref +
  session snapshot; non-git cwd degrades cleanly; the idle receipt timing is
  unchanged (pinned). NO rollback, NO web UI. This is landable on its own (capture
  is inert until something restores).
- **S18b — rollback + UI:** the `checkpoint_rollback` op (restore both halves +
  relaunch via the resume() path), the safety-checkpoint-before-rollback, and the
  web timeline/rewind UI (a per-turn "restore to here" affordance in the
  transcript or a checkpoints panel) + destructive-confirm. Optional checkpoint
  diff view (reuse S9/S10). e2e: run 2 turns each writing a file, roll back to
  turn 1, assert the turn-2 file is gone AND the conversation is truncated to
  turn 1; visual baseline for the rewind UI.

## Risks / invariants

- **Never mutate pi's session file content** — snapshot/restore by copy only.
- **Capture must not perturb the turn** — fork off idle, best-effort, receipt
  timing unchanged (the whole e2e suite depends on it).
- **git capture must not disturb the user's index/working tree** — use a
  temp-index / tree-capture, not `git add -A` against the real index followed by
  reset.
- **Rollback is destructive** — confirm in UI; capture a safety checkpoint first.
- **Consistency** — a partial rollback (files restored, conversation not, or vice
  versa) is the worst outcome; order the restore so a failure leaves the session
  stoppable and re-openable, and surface a clear error rather than a half-state.
- **Worktree sessions** — `checkpointCwd = meta.worktreePath ?? meta.cwd`; a
  worktree session's checkpoints live in its own branch/checkout, which is the
  natural isolation.
