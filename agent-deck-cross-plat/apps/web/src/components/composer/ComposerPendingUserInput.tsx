import type { QuestionCell } from "@agent-deck/domain";
import { QuestionAnswerControls } from "../QuestionAnswerControls.tsx";

/**
 * Slice 17 — composer-anchored pending user-input panel.
 *
 * pi raises a blocking `extension_ui_request` (input / select / editor / confirm)
 * that already renders as a `question-cell` in the transcript. This surfaces the
 * SAME open request right above the composer so it is answerable without scrolling
 * back to the card. It is a pure view over the transcript's open `question` cell
 * (domain `openQuestion`) and answers through our EXISTING `ui_response`
 * pass-through via the shared {@link QuestionAnswerControls} (also used by the
 * transcript card), with no wire change. The server resolves the request and
 * emits `question_answered`, which marks the cell answered so this panel (and the
 * transcript card) drop out together.
 */
export function ComposerPendingUserInput({ question }: { question: QuestionCell }) {
  return (
    <div
      className="border-b border-border-subtle px-4 py-3"
      style={{ background: "var(--color-selection-fill)" }}
      data-testid="composer-question"
      data-method={question.method}
    >
      <div className="text-[11px] font-semibold uppercase tracking-widest text-text-muted">
        Pi needs input
      </div>
      <div className="mt-1 font-medium text-text-primary" style={{ fontStretch: "expanded" }}>
        {question.title}
      </div>
      {question.message ? (
        <div className="mt-1 text-sm text-text-secondary">{question.message}</div>
      ) : null}

      <QuestionAnswerControls question={question} testidPrefix="composer-question" />
    </div>
  );
}
