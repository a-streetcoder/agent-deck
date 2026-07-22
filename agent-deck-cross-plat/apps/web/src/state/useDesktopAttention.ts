import { useEffect, useRef } from "react";
import { openQuestion } from "@agent-deck/domain";
import { isElectron, signalAttention } from "@/lib/native";
import { projectDisplayName, sessionDisplayTitle } from "@/lib/sessionTitle";
import { useAppStore } from "./store.ts";

/** Cap the notification body so a long approval prompt stays a one-liner. */
const MAX_BODY = 140;

function truncate(text: string, max = MAX_BODY): string {
  const trimmed = text.trim();
  return trimmed.length > max ? `${trimmed.slice(0, max - 1)}…` : trimmed;
}

export type AttentionKind = "turn-complete" | "approval-needed";

/** The active-session state this hook watches for attention-worthy edges. */
export interface AttentionState {
  readonly status: "idle" | "running";
  /** openQuestion(transcript)?.id — the id of the pending approval, or null. */
  readonly questionId: string | null;
}

/**
 * PURE edge-detection (the load-bearing, testable core of {@link useDesktopAttention}):
 * which attention signals a transition from `prev` to `next` should raise.
 *
 *   - turn-complete — the agent went running → idle.
 *   - approval-needed — a NEW distinct pending approval appeared. This fires on
 *     any change to a non-null question id (null→id AND id→different-id), so a
 *     second consecutive approval in the same session still notifies — not only
 *     the null→non-null edge.
 *
 * Returns [] when not in the desktop shell, or on a session switch (`prev`
 * belongs to the OLD session, so the change is a re-baseline, not a real edge —
 * this is what stops a phantom notification when the user just switched
 * sessions). `prev` is null before the first observation (also a re-baseline).
 *
 * NOTE: a wholesale snapshot swap on the SAME session (e.g. a checkpoint rollback
 * that restores an idle snapshot over a running one) reads as a real running→idle
 * edge here and would raise turn-complete. That is harmless in practice: rollback
 * is a user-initiated, window-focused action, and MAIN gates every signal on
 * `!isFocused()`, so the notification/badge is suppressed.
 */
export function attentionEventsFor(
  prev: AttentionState | null,
  next: AttentionState,
): AttentionKind[] {
  if (prev === null) return [];
  const events: AttentionKind[] = [];
  if (prev.status === "running" && next.status === "idle") events.push("turn-complete");
  if (next.questionId !== null && next.questionId !== prev.questionId) {
    events.push("approval-needed");
  }
  return events;
}

/**
 * Bridge ACTIVE-session domain transitions to native desktop attention (Slice
 * 22a). When running inside the Electron shell, forward a semantic event on a
 * turn completing (running → idle) or a new approval request appearing.
 *
 * The MAIN process owns the focus gate and the OS notification/badge, so this
 * only DETECTS the transition (via the pure {@link attentionEventsFor}) and
 * forwards it once per edge — never gates on focus here, never fires per render.
 * Watched via the store's active-session transcript, so both signals track the
 * session the user is actually looking at. A session switch re-baselines the
 * refs WITHOUT firing (the previous state belonged to the old session).
 */
export function useDesktopAttention(): void {
  const sessionId = useAppStore((state) => state.session?.id ?? null);
  const agentStatus = useAppStore((state) => state.transcript.agentStatus);
  const questionId = useAppStore((state) => openQuestion(state.transcript)?.id ?? null);

  const sessionRef = useRef<string | null>(null);
  const prevRef = useRef<AttentionState | null>(null);

  useEffect(() => {
    const sessionChanged = sessionRef.current !== sessionId;
    sessionRef.current = sessionId;
    const prev = prevRef.current;
    const next: AttentionState = { status: agentStatus, questionId };
    prevRef.current = next;

    // Re-baseline (no fire) in a plain browser, or right after a session switch
    // (the previous state belonged to the old session — not a real edge).
    if (!isElectron() || sessionChanged) return;

    const events = attentionEventsFor(prev, next);
    if (events.length === 0) return;

    const title = (): string => {
      const { session, projects } = useAppStore.getState();
      return session
        ? sessionDisplayTitle(session.title, projectDisplayName(projects, session.projectId))
        : "Agent Deck";
    };

    if (events.includes("turn-complete")) {
      signalAttention({
        kind: "turn-complete",
        title: title(),
        body: "Turn complete",
        sessionId: sessionId ?? undefined,
      });
    }
    if (events.includes("approval-needed")) {
      const question = openQuestion(useAppStore.getState().transcript);
      signalAttention({
        kind: "approval-needed",
        title: title(),
        body: truncate(question?.message || question?.title || "Approval needed"),
        sessionId: sessionId ?? undefined,
      });
    }
  }, [sessionId, agentStatus, questionId]);
}
