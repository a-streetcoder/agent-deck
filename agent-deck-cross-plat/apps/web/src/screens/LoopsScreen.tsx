import { useCallback, useEffect, useRef, useState } from "react";
import { Play, Plus, Repeat, Square, Trash2 } from "lucide-react";
import {
  isLoopRunTerminal,
  LOOP_DEFAULT_MAX_ITERATIONS,
  LOOP_MAX_ITERATIONS_LIMIT,
  LOOP_STRUCTURE_LABEL,
  LOOP_STRUCTURES,
  LOOP_WRITE_TARGET_LABEL,
  LOOP_WRITE_TARGETS,
  type LoopDefinition,
  type LoopRun,
} from "@agent-deck/domain";
import { useAppStore } from "../state/store.ts";

/**
 * Loop Bank (native LoopBankScreen): the library of saved loop definitions —
 * create, edit, delete, and RUN. Running a loop iterates its agent (via the
 * server's run engine) until the validation command exits 0; a live panel polls
 * the run state and can stop it.
 */
const RUN_STATUS_LABEL: Record<LoopRun["status"], string> = {
  running: "Running",
  stopping: "Stopping…",
  completed: "Completed",
  failed: "Failed",
  stopped: "Stopped",
};
const inputClass =
  "w-full rounded-lg border border-border-strong bg-surface px-2.5 py-1.5 text-sm text-text-primary outline-none focus:border-accent";

interface LoopDraft {
  original: string | null; // the name at open time (null = new); edit keeps the name fixed
  name: string;
  description: string;
  goal: string;
  structure: LoopDefinition["structure"];
  agentName: string;
  maxIterations: number;
  validationCommand: string;
  writeTarget: LoopDefinition["writeTarget"];
}

function draftFrom(loop: LoopDefinition | null): LoopDraft {
  return {
    original: loop?.name ?? null,
    name: loop?.name ?? "",
    description: loop?.description ?? "",
    goal: loop?.goal ?? "",
    structure: loop?.structure ?? "singleAgent",
    agentName: loop?.agentName ?? "",
    maxIterations: loop?.maxIterations ?? LOOP_DEFAULT_MAX_ITERATIONS,
    validationCommand: loop?.validationCommand ?? "",
    writeTarget: loop?.writeTarget ?? "artifactMarkdown",
  };
}

export function LoopsScreen() {
  const setError = useAppStore((state) => state.setError);
  const resourcesVersion = useAppStore((state) => state.resourcesVersion);
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const [loops, setLoops] = useState<LoopDefinition[]>([]);
  const [draft, setDraft] = useState<LoopDraft | null>(null);
  const [saving, setSaving] = useState(false);
  const [activeRun, setActiveRun] = useState<LoopRun | null>(null);
  const runIdRef = useRef<string | null>(null);

  const load = useCallback(async (): Promise<void> => {
    try {
      const response = await fetch("/loops");
      if (!response.ok) throw new Error(await response.text());
      const data = (await response.json()) as { loops: LoopDefinition[] };
      setLoops(data.loops);
    } catch (err) {
      setError(String(err));
    }
  }, [setError]);

  useEffect(() => {
    void load();
  }, [load, resourcesVersion]);

  const save = async (): Promise<void> => {
    if (!draft || !draft.name.trim()) return;
    setSaving(true);
    setError(null);
    try {
      const response = await fetch("/loops", {
        method: "PUT",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          name: draft.name.trim(),
          description: draft.description,
          goal: draft.goal,
          structure: draft.structure,
          agentName: draft.agentName.trim(),
          maxIterations: draft.maxIterations,
          validationCommand: draft.validationCommand,
          writeTarget: draft.writeTarget,
        }),
      });
      if (!response.ok) throw new Error(await response.text());
      setDraft(null);
      await load();
    } catch (err) {
      setError(String(err));
    } finally {
      setSaving(false);
    }
  };

  const remove = async (loop: LoopDefinition): Promise<void> => {
    if (!confirm(`Delete the loop "${loop.name}"?`)) return;
    try {
      const response = await fetch("/loops", {
        method: "DELETE",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: loop.name }),
      });
      if (!response.ok) throw new Error(await response.text());
      await load();
    } catch (err) {
      setError(String(err));
    }
  };

  const startRun = async (loop: LoopDefinition): Promise<void> => {
    if (!currentProjectId) return;
    setError(null);
    try {
      const response = await fetch(`/loops/${encodeURIComponent(loop.name)}/run`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ projectId: currentProjectId }),
      });
      if (!response.ok) throw new Error(await response.text());
      const { run } = (await response.json()) as { run: LoopRun };
      runIdRef.current = run.id;
      setActiveRun(run);
    } catch (err) {
      setError(String(err));
    }
  };

  const stopRun = async (): Promise<void> => {
    const id = runIdRef.current;
    if (!id) return;
    await fetch(`/loops/runs/${id}/stop`, { method: "POST" }).catch(() => {});
  };

  // Poll the active run until it reaches a terminal state.
  useEffect(() => {
    if (!activeRun || isLoopRunTerminal(activeRun.status)) return;
    const id = activeRun.id;
    const timer = setInterval(() => {
      void (async () => {
        try {
          const response = await fetch(`/loops/runs/${id}`);
          if (!response.ok) return;
          const { run } = (await response.json()) as { run: LoopRun };
          // Ignore a stale poll if a newer run was started, and never let an
          // out-of-order older snapshot regress a run that already finished.
          if (runIdRef.current === run.id) {
            setActiveRun((prev) =>
              prev && prev.id === run.id && isLoopRunTerminal(prev.status) ? prev : run,
            );
          }
        } catch {
          // Transient — the next tick retries.
        }
      })();
    }, 500);
    return () => clearInterval(timer);
  }, [activeRun]);

  return (
    <div className="min-h-0 flex-1 overflow-y-auto px-6 py-5" data-testid="loops-screen">
      <div className="mx-auto max-w-3xl">
        <div className="flex items-center justify-between pb-1">
          <div className="flex items-center gap-2">
            <Repeat size={16} className="text-text-secondary" aria-hidden />
            <h2
              className="text-base font-semibold text-text-primary"
              style={{ fontStretch: "expanded" }}
            >
              Loop Bank
            </h2>
          </div>
          <button
            data-testid="new-loop"
            className="flex items-center gap-1.5 rounded-capsule px-3 py-1 text-xs font-medium shadow-capsule"
            style={{
              background:
                "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
              color: "var(--color-accent-foreground)",
            }}
            onClick={() => setDraft(draftFrom(null))}
          >
            <Plus size={13} /> New loop
          </button>
        </div>
        <p className="pb-3 text-xs text-text-muted">
          Saved loops repeat an agent run until the validation command passes.
          {currentProjectId ? " Run one in the current project." : " Open a project to run one."}
        </p>

        {activeRun ? (
          <div
            className="mb-3 rounded-xl border border-border-strong bg-surface-elevated px-3.5 py-3"
            data-testid="loop-run-panel"
          >
            <div className="flex items-center justify-between">
              <div
                className="text-sm font-medium text-text-primary"
                style={{ fontStretch: "expanded" }}
              >
                {activeRun.loopName}
              </div>
              <div className="flex items-center gap-2">
                <span
                  data-testid="loop-run-status"
                  data-status={activeRun.status}
                  className="rounded-capsule border border-border-strong px-2 py-0.5 text-[11px] text-text-secondary"
                >
                  {RUN_STATUS_LABEL[activeRun.status]}
                </span>
                {isLoopRunTerminal(activeRun.status) ? (
                  <button
                    data-testid="loop-run-dismiss"
                    className="rounded p-1 text-text-muted hover:text-text-primary"
                    title="Dismiss"
                    onClick={() => {
                      runIdRef.current = null;
                      setActiveRun(null);
                    }}
                  >
                    <Trash2 size={13} />
                  </button>
                ) : (
                  <button
                    data-testid="loop-run-stop"
                    className="flex items-center gap-1 rounded-capsule border border-border-strong px-2 py-0.5 text-[11px] text-text-secondary hover:text-[var(--color-role-error)]"
                    onClick={() => void stopRun()}
                  >
                    <Square size={11} /> Stop
                  </button>
                )}
              </div>
            </div>
            <div className="mt-1 text-[11px] text-text-muted">
              Iteration {activeRun.currentIteration} / {activeRun.maxIterations}
              {activeRun.stopReason ? ` · ${activeRun.stopReason}` : ""}
            </div>
            {activeRun.iterations.length > 0 ? (
              <div className="mt-2 flex flex-wrap gap-1" data-testid="loop-run-iterations">
                {activeRun.iterations.map((it) => (
                  <span
                    key={it.index}
                    className="rounded-capsule border px-1.5 py-0.5 text-[10px]"
                    style={{
                      borderColor:
                        it.validationPassed === true
                          ? "var(--color-success)"
                          : it.validationPassed === false
                            ? "var(--color-warning)"
                            : "var(--color-border-strong)",
                      color:
                        it.validationPassed === true
                          ? "var(--color-success)"
                          : "var(--color-text-secondary)",
                    }}
                  >
                    #{it.index}{" "}
                    {it.validationPassed === true ? "✓" : it.validationPassed === false ? "✗" : "·"}
                  </span>
                ))}
              </div>
            ) : null}
          </div>
        ) : null}

        <div className="space-y-1.5" data-testid="loop-list">
          {loops.map((loop) => (
            <div
              key={loop.id}
              data-loop-name={loop.name}
              className="flex items-center gap-3 rounded-[14px] border border-border-subtle bg-surface px-3.5 py-2.5"
            >
              <button
                className="min-w-0 flex-1 text-left"
                onClick={() => setDraft(draftFrom(loop))}
                data-testid={`loop-open-${loop.name}`}
              >
                <div
                  className="truncate text-sm font-medium text-text-primary"
                  style={{ fontStretch: "expanded" }}
                >
                  {loop.name}
                </div>
                <div className="truncate text-[11px] text-text-muted">
                  {LOOP_STRUCTURE_LABEL[loop.structure]} · {loop.maxIterations}× ·{" "}
                  {loop.description || "No description"}
                </div>
              </button>
              <button
                data-testid={`loop-run-${loop.name}`}
                className="flex items-center gap-1 rounded-capsule border border-border-strong px-2.5 py-1 text-xs text-text-secondary hover:text-text-primary disabled:opacity-40"
                title={currentProjectId ? "Run loop" : "Open a project to run"}
                disabled={!currentProjectId}
                onClick={() => void startRun(loop)}
              >
                <Play size={12} /> Run
              </button>
              <button
                data-testid={`loop-delete-${loop.name}`}
                className="rounded p-1 text-text-muted hover:text-[var(--color-role-error)]"
                title="Delete loop"
                onClick={() => void remove(loop)}
              >
                <Trash2 size={13} />
              </button>
            </div>
          ))}
          {loops.length === 0 ? (
            <div className="py-8 text-center text-sm text-text-muted" data-testid="loop-empty">
              No loops yet. Create one to iterate an agent toward a checked goal.
            </div>
          ) : null}
        </div>
      </div>

      {draft ? (
        <div
          className="fixed inset-0 z-40 flex items-center justify-center bg-black/40 p-8"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) setDraft(null);
          }}
        >
          <div
            className="flex max-h-[85vh] w-[560px] flex-col gap-3 overflow-y-auto rounded-2xl border border-border-strong bg-surface-elevated p-4 shadow-elevated"
            data-testid="loop-editor"
            role="dialog"
            aria-modal="true"
          >
            <div
              className="text-sm font-semibold text-text-primary"
              style={{ fontStretch: "expanded" }}
            >
              {draft.original ? `Edit ${draft.original}` : "New Loop"}
            </div>
            <label className="block text-xs text-text-muted">
              Name
              <input
                data-testid="loop-name"
                className={inputClass}
                value={draft.name}
                disabled={draft.original !== null}
                onChange={(e) => setDraft({ ...draft, name: e.target.value })}
              />
            </label>
            <label className="block text-xs text-text-muted">
              Description
              <input
                className={inputClass}
                value={draft.description}
                onChange={(e) => setDraft({ ...draft, description: e.target.value })}
              />
            </label>
            <label className="block text-xs text-text-muted">
              Goal (what each iteration should accomplish)
              <textarea
                data-testid="loop-goal"
                className={`${inputClass} min-h-[100px] font-mono text-[12px]`}
                value={draft.goal}
                onChange={(e) => setDraft({ ...draft, goal: e.target.value })}
              />
            </label>
            <div className="grid grid-cols-2 gap-3">
              <label className="text-xs text-text-muted">
                Structure
                <select
                  data-testid="loop-structure"
                  className={inputClass}
                  value={draft.structure}
                  onChange={(e) =>
                    setDraft({ ...draft, structure: e.target.value as LoopDraft["structure"] })
                  }
                >
                  {LOOP_STRUCTURES.map((s) => (
                    <option key={s} value={s}>
                      {LOOP_STRUCTURE_LABEL[s]}
                    </option>
                  ))}
                </select>
              </label>
              <label className="text-xs text-text-muted">
                Agent
                <input
                  className={inputClass}
                  placeholder="agent name"
                  value={draft.agentName}
                  onChange={(e) => setDraft({ ...draft, agentName: e.target.value })}
                />
              </label>
            </div>
            <div className="grid grid-cols-2 gap-3">
              <label className="text-xs text-text-muted">
                Max iterations
                <input
                  data-testid="loop-max-iterations"
                  type="number"
                  min={1}
                  max={LOOP_MAX_ITERATIONS_LIMIT}
                  className={inputClass}
                  value={draft.maxIterations}
                  onChange={(e) =>
                    setDraft({ ...draft, maxIterations: Number(e.target.value) || 1 })
                  }
                />
              </label>
              <label className="text-xs text-text-muted">
                Write target
                <select
                  className={inputClass}
                  value={draft.writeTarget}
                  onChange={(e) =>
                    setDraft({ ...draft, writeTarget: e.target.value as LoopDraft["writeTarget"] })
                  }
                >
                  {LOOP_WRITE_TARGETS.map((t) => (
                    <option key={t} value={t}>
                      {LOOP_WRITE_TARGET_LABEL[t]}
                    </option>
                  ))}
                </select>
              </label>
            </div>
            <label className="block text-xs text-text-muted">
              Validation command (exit 0 stops the loop early)
              <input
                data-testid="loop-validation"
                className={`${inputClass} font-mono text-[12px]`}
                placeholder="pnpm test"
                value={draft.validationCommand}
                onChange={(e) => setDraft({ ...draft, validationCommand: e.target.value })}
              />
            </label>
            <div className="flex justify-end gap-2 pt-1">
              <button
                className="rounded-capsule border border-border-strong px-4 py-1.5 text-sm text-text-secondary hover:text-text-primary"
                onClick={() => setDraft(null)}
              >
                Cancel
              </button>
              <button
                data-testid="loop-save"
                className="rounded-capsule px-4 py-1.5 text-sm font-medium shadow-capsule disabled:opacity-40"
                style={{
                  background:
                    "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
                  color: "var(--color-accent-foreground)",
                }}
                disabled={saving || !draft.name.trim()}
                onClick={() => void save()}
              >
                {saving ? "Saving…" : "Save"}
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}
