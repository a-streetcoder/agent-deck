import { useEffect, useState } from "react";
import { FileWarning, History, RefreshCw, RotateCcw, X } from "lucide-react";
import type { CheckpointInfo } from "@agent-deck/contracts";
import { cn } from "@/lib/cn";
import { useAppStore } from "../state/store.ts";
import { refreshCheckpoints, rollbackToCheckpoint } from "../state/wsBridge.ts";

/**
 * The checkpoints / rewind timeline panel (Slice 18b): a right-hand aside on the
 * chat surface, a sibling to the diff + files panels (same shell idiom — a
 * fixed-width column with a subheader row). It lists the CURRENT session's
 * captured checkpoints — one per turn — and offers a DESTRUCTIVE rollback to a
 * prior turn. This is the "checkpoints panel" alternative to per-turn transcript
 * affordances the design doc allows; a panel is the tractable idiom here because
 * a checkpoint's per-session capture index doesn't map 1:1 onto a transcript
 * cell id, and it matches our diff/files panel pattern.
 *
 * Rollback is destructive (it discards the conversation + uncommitted files
 * after the chosen turn), so clicking "Restore" opens a confirm dialog first;
 * on confirm it fires `checkpoint_rollback` and the transcript reloads to the
 * restored state (the server re-pushes a fresh snapshot on the same connection).
 *
 * Newest capture is shown on top (the natural "rewind" reading order). A session
 * with no checkpoints renders an empty hint, never an error.
 */
export function CheckpointsPanel() {
  const open = useAppStore((state) => state.checkpointsPanelOpen);
  const setOpen = useAppStore((state) => state.setCheckpointsPanelOpen);
  const sessionId = useAppStore((state) => state.session?.id ?? null);
  const checkpoints = useAppStore((state) => state.checkpoints);
  // Rollback is only safe when the agent is idle: a checkpoint is captured at
  // the turn boundary, and stopping pi mid-turn to restore a snapshot would race
  // an in-flight turn (and could snapshot a half-written worktree). So the
  // Restore affordance is idle-gated — disabled while a turn is running.
  const running = useAppStore((state) => state.transcript.agentStatus === "running");

  // The turnIndex awaiting confirmation, or null when no dialog is open.
  const [confirming, setConfirming] = useState<number | null>(null);
  // True while a rollback is in flight (disables the controls, shows progress).
  const [rollingBack, setRollingBack] = useState(false);

  // Fetch on open (the idle-refresh may not have run yet for this session).
  useEffect(() => {
    if (open && sessionId !== null) void refreshCheckpoints(sessionId);
  }, [open, sessionId]);

  // A session switch closes any open confirm dialog.
  useEffect(() => {
    setConfirming(null);
  }, [sessionId]);

  // A turn starting while the confirm dialog is open closes it (unless a
  // rollback is already committing) — the target may no longer be the newest
  // idle state, so the operator must re-open against the fresh timeline.
  useEffect(() => {
    if (running && !rollingBack) setConfirming(null);
  }, [running, rollingBack]);

  if (!open || sessionId === null) return null;

  // Newest capture first (the list arrives oldest-first).
  const ordered = [...checkpoints].reverse();
  const confirmTarget =
    confirming !== null ? (checkpoints.find((c) => c.turnIndex === confirming) ?? null) : null;

  const doRollback = async (turnIndex: number): Promise<void> => {
    setRollingBack(true);
    try {
      const { filesRestored } = await rollbackToCheckpoint(turnIndex);
      setConfirming(null);
      if (!filesRestored) {
        useAppStore.getState().pushToast({
          kind: "info",
          message: "Conversation restored. This session's files were not (no git snapshot).",
        });
      } else {
        useAppStore
          .getState()
          .pushToast({ kind: "success", message: "Rolled back to the checkpoint." });
      }
    } catch (error) {
      useAppStore.getState().setError(error instanceof Error ? error.message : String(error));
    } finally {
      setRollingBack(false);
    }
  };

  return (
    <aside
      className="flex w-[300px] shrink-0 flex-col overflow-hidden border-l border-border-subtle bg-surface-elevated"
      data-testid="checkpoints-panel"
    >
      {/* Subheader row (matches the diff / files panels). */}
      <div className="flex items-center justify-between gap-2 border-b border-border-subtle px-3 py-2">
        <span
          className="text-xs font-semibold uppercase tracking-wide text-text-muted"
          style={{ fontStretch: "expanded" }}
        >
          Checkpoints
        </span>
        <div className="flex shrink-0 items-center gap-1">
          <button
            type="button"
            className="rounded p-1 text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
            title="Refresh checkpoints"
            aria-label="Refresh checkpoints"
            data-testid="checkpoints-refresh"
            onClick={() => void refreshCheckpoints(sessionId)}
          >
            <RefreshCw className="h-3.5 w-3.5" />
          </button>
          <button
            type="button"
            className="rounded p-1 text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
            title="Close checkpoints panel"
            aria-label="Close checkpoints panel"
            data-testid="checkpoints-close"
            onClick={() => setOpen(false)}
          >
            <X className="h-3.5 w-3.5" />
          </button>
        </div>
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto px-2 py-2" data-testid="checkpoints-list">
        {ordered.length === 0 ? (
          <p
            className="px-2 py-6 text-center text-xs text-text-muted"
            data-testid="checkpoints-empty"
          >
            No checkpoints yet. Each completed turn captures one.
          </p>
        ) : (
          <ol className="space-y-1.5">
            {ordered.map((checkpoint) => (
              <CheckpointRow
                key={checkpoint.turnIndex}
                checkpoint={checkpoint}
                disabled={running}
                onRestore={() => setConfirming(checkpoint.turnIndex)}
              />
            ))}
          </ol>
        )}
      </div>

      {confirmTarget !== null ? (
        <RollbackConfirmDialog
          checkpoint={confirmTarget}
          busy={rollingBack}
          onCancel={() => setConfirming(null)}
          onConfirm={() => void doRollback(confirmTarget.turnIndex)}
        />
      ) : null}
    </aside>
  );
}

function CheckpointRow({
  checkpoint,
  disabled,
  onRestore,
}: {
  checkpoint: CheckpointInfo;
  disabled: boolean;
  onRestore: () => void;
}) {
  const label = checkpoint.label.trim().length > 0 ? checkpoint.label : "(no message)";
  return (
    <li
      className="group/checkpoint rounded-md border border-border-subtle bg-surface px-2.5 py-2"
      data-testid="checkpoint-row"
      data-turn={checkpoint.turnIndex}
    >
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0 flex-1">
          <p className="truncate text-xs font-medium text-text-primary" title={label}>
            {label}
          </p>
          <div className="mt-0.5 flex items-center gap-1.5 text-[10px] text-text-muted">
            <span data-testid="checkpoint-time">{formatTime(checkpoint.createdAt)}</span>
            {!checkpoint.hasFiles ? (
              <span
                className="inline-flex items-center gap-0.5 text-[var(--color-warning)]"
                title="No file snapshot (non-git session) — a rollback restores only the conversation."
                data-testid="checkpoint-no-files"
              >
                <FileWarning className="h-3 w-3" />
                conversation only
              </span>
            ) : null}
          </div>
        </div>
        <button
          type="button"
          className={cn(
            "shrink-0 rounded p-1 text-text-muted transition-colors",
            "hover:bg-[var(--color-hover-fill)] hover:text-text-primary",
            "disabled:cursor-not-allowed disabled:opacity-40 disabled:hover:bg-transparent disabled:hover:text-text-muted",
          )}
          title={disabled ? "Wait for the current turn to finish" : "Restore to this point"}
          aria-label="Restore to this point"
          data-testid="checkpoint-restore"
          disabled={disabled}
          onClick={onRestore}
        >
          <RotateCcw className="h-3.5 w-3.5" />
        </button>
      </div>
    </li>
  );
}

/** The destructive-confirm dialog: a modal overlay over the panel, warning that
 * rollback discards work after the chosen turn. */
function RollbackConfirmDialog({
  checkpoint,
  busy,
  onCancel,
  onConfirm,
}: {
  checkpoint: CheckpointInfo;
  busy: boolean;
  onCancel: () => void;
  onConfirm: () => void;
}) {
  useEffect(() => {
    const onKeyDown = (event: globalThis.KeyboardEvent): void => {
      if (event.key === "Escape" && !busy) {
        event.preventDefault();
        onCancel();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [busy, onCancel]);

  const label = checkpoint.label.trim().length > 0 ? checkpoint.label : "this turn";

  return (
    <div
      // A VIEWPORT-fixed centered modal (the ExpandedImageDialog idiom), not an
      // in-panel overlay: the panel sits inside the chat layout whose height
      // flakes ±sub-pixel with the composer's post-turn settle, which would land
      // an in-panel dialog at a fractional device-Y and rasterize its fixed
      // height to ±1px. Centering an even-height box in the fixed viewport keeps
      // its top on an integer device pixel, so the screenshot is deterministic.
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 px-4"
      role="dialog"
      aria-modal="true"
      aria-label="Confirm rollback"
      data-testid="rollback-confirm"
    >
      <div
        // Explicit fixed height so the screenshot dimensions are deterministic
        // (auto-height text sub-pixel-rounds ±1px run-to-run); the dynamic label
        // rides its own truncated line so a long checkpoint name never overflows.
        className="flex h-[188px] w-full max-w-[280px] flex-col rounded-lg border border-border-strong bg-surface p-4 shadow-card"
        data-testid="rollback-confirm-dialog"
      >
        <div className="mb-2 flex items-center gap-2">
          <History className="h-4 w-4 text-[var(--color-warning)]" />
          <h2 className="text-sm font-semibold text-text-primary">Roll back the session?</h2>
        </div>
        <p className="text-xs leading-[18px] text-text-muted">Restore the session to:</p>
        <p className="truncate text-xs font-medium leading-[18px] text-text-primary" title={label}>
          “{label}”
        </p>
        <p className="mt-1.5 text-xs leading-[18px] text-text-muted">
          This{" "}
          <span className="font-medium text-[var(--color-warning)]">
            discards all messages and uncommitted file changes after this turn
          </span>
          . A safety checkpoint of the current state is kept so you can undo it.
        </p>
        <div className="mt-auto flex justify-end gap-2">
          <button
            type="button"
            className="rounded-md px-3 py-1.5 text-xs font-medium text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary disabled:opacity-50"
            data-testid="rollback-cancel"
            disabled={busy}
            onClick={onCancel}
          >
            Cancel
          </button>
          <button
            type="button"
            className="rounded-md px-3 py-1.5 text-xs font-semibold text-white transition-opacity hover:opacity-90 disabled:opacity-50"
            style={{ background: "var(--color-role-error)" }}
            data-testid="rollback-confirm-button"
            disabled={busy}
            onClick={onConfirm}
          >
            {busy ? "Restoring…" : "Roll back"}
          </button>
        </div>
      </div>
    </div>
  );
}

/** A short, locale-stable clock time for a checkpoint's capture instant. */
function formatTime(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}
