import type { PlanItemStatus, SessionPlanItem } from "@agent-deck/domain";
import { ProgressRing } from "./ProgressRing.tsx";
import { useAppStore } from "../state/store.ts";

/**
 * The session's activity plan (native activity-sidebar "Plan" card), driven by a
 * parent agent via set_session_plan / update_session_plan. Shows a done-count,
 * a progress bar, and one row per item with a status glyph — mirroring the
 * native PiAgentCurrentPlanCard.
 */

const STATUS_GLYPH: Record<PlanItemStatus, string> = {
  todo: "○",
  in_progress: "◐",
  done: "●",
  blocked: "▲",
  skipped: "—",
};

const STATUS_COLOR: Record<PlanItemStatus, string> = {
  todo: "var(--color-text-muted)",
  in_progress: "var(--color-accent)",
  done: "var(--color-diff-added, #2e7d32)",
  blocked: "var(--color-role-tool, #b26a00)",
  skipped: "var(--color-text-muted)",
};

function isComplete(status: PlanItemStatus): boolean {
  return status === "done" || status === "skipped";
}

function PlanRow({ item }: { item: SessionPlanItem }) {
  const muted = isComplete(item.status);
  return (
    <li
      className="flex items-start gap-2 text-sm"
      data-testid="plan-item"
      data-status={item.status}
    >
      <span aria-hidden style={{ color: STATUS_COLOR[item.status] }} className="leading-5">
        {STATUS_GLYPH[item.status]}
      </span>
      <span
        className={muted ? "text-text-muted line-through" : "text-text-primary"}
        style={{ textDecorationColor: "var(--color-text-muted)" }}
      >
        {item.title}
      </span>
    </li>
  );
}

export function SessionPlanPanel() {
  const plan = useAppStore((state) => state.transcript.plan);
  if (plan.length === 0) return null;

  const done = plan.filter((it) => isComplete(it.status)).length;

  return (
    <section
      className="rounded-xl border px-4 py-3"
      style={{ borderColor: "var(--color-border-strong)", background: "var(--color-surface)" }}
      data-testid="session-plan"
    >
      <div className="flex items-center justify-between">
        <div className="text-xs font-medium uppercase tracking-wide text-text-muted">Plan</div>
        <div className="flex items-center gap-2">
          <span className="text-xs tabular-nums text-text-muted" data-testid="plan-progress">
            {done}/{plan.length}
          </span>
          <ProgressRing done={done} total={plan.length} />
        </div>
      </div>
      <ul className="mt-3 space-y-1.5">
        {plan.map((item) => (
          <PlanRow key={item.id} item={item} />
        ))}
      </ul>
    </section>
  );
}
