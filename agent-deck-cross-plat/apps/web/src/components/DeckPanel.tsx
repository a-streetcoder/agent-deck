import { useMemo } from "react";
import { deckRuns, type DeckRun } from "@agent-deck/domain";
import { RunMeta } from "./RunMeta.tsx";
import { useAppStore } from "../state/store.ts";

/**
 * The deck: a per-session activity panel that aggregates the session's native
 * subagent runs (native activity-sidebar "Deck Agents"). v1 derives everything
 * from the transcript's subagent + supervisor cells (deckRuns) — no server state.
 * Renders nothing when there are no runs, so it only claims width when active.
 */

const STATUS_LABEL: Record<DeckRun["status"], string> = {
  running: "Running",
  done: "Done",
  error: "Failed",
};

const STATUS_COLOR: Record<DeckRun["status"], string> = {
  running: "var(--color-brand-accent, var(--color-accent))",
  done: "var(--color-diff-added, #2e7d32)",
  error: "var(--color-role-tool, #b26a00)",
};

function RunRow({ run }: { run: DeckRun }) {
  return (
    <li
      className="rounded-lg border px-3 py-2"
      style={{ borderColor: "var(--color-border-strong)", background: "var(--color-surface)" }}
      data-testid="deck-run"
      data-status={run.status}
      data-needs-input={run.needsInput ? "true" : "false"}
    >
      <div className="flex items-center justify-between gap-2">
        <span
          className="rounded-capsule px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide"
          style={{
            color: STATUS_COLOR[run.status],
            border: `1px solid ${STATUS_COLOR[run.status]}`,
          }}
        >
          {STATUS_LABEL[run.status]}
        </span>
        {run.needsInput ? (
          <span
            className="rounded-capsule px-2 py-0.5 text-[10px] font-medium"
            style={{ color: "var(--color-accent-foreground)", background: "var(--color-accent)" }}
            data-testid="deck-run-needs-input"
          >
            Needs input
          </span>
        ) : run.progressCount > 0 ? (
          <span className="text-[10px] tabular-nums text-text-muted">
            {run.progressCount} update(s)
          </span>
        ) : null}
      </div>
      <div className="mt-1.5 line-clamp-3 text-xs text-text-secondary">{run.task}</div>
      <RunMeta
        className="mt-1.5"
        model={run.model}
        inputTokens={run.inputTokens}
        outputTokens={run.outputTokens}
        durationMs={run.durationMs}
      />
    </li>
  );
}

export function DeckPanel() {
  // Select the stable transcript reference (it only changes when the store
  // reduces a new event) and derive the runs with useMemo — selecting a
  // freshly-allocated array directly would defeat zustand's snapshot caching.
  const transcript = useAppStore((state) => state.transcript);
  const runs = useMemo(() => deckRuns(transcript), [transcript]);
  if (runs.length === 0) return null;

  const active = runs.filter((r) => r.status === "running").length;

  return (
    <aside
      className="flex w-72 shrink-0 flex-col overflow-hidden border-l border-border-subtle bg-surface-elevated"
      data-testid="deck-panel"
    >
      <div className="flex items-center justify-between border-b border-border-subtle px-4 py-2.5">
        <span
          className="text-xs font-semibold uppercase tracking-wide text-text-primary"
          style={{ fontStretch: "expanded" }}
        >
          Deck
        </span>
        <span className="text-xs tabular-nums text-text-muted" data-testid="deck-count">
          {active > 0 ? `${active} active · ` : ""}
          {runs.length}
        </span>
      </div>
      <ul className="flex-1 space-y-2 overflow-y-auto px-3 py-3">
        {runs.map((run) => (
          <RunRow key={run.id} run={run} />
        ))}
      </ul>
    </aside>
  );
}
