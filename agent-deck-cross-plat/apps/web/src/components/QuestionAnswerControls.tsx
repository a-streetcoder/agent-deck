import { useEffect, useState } from "react";
import type { QuestionCell } from "@agent-deck/domain";
import { sendUiResponse } from "../state/wsBridge.ts";

/**
 * The interactive answer controls for a single open `extension_ui_request`
 * (confirm / select / editor / input) plus Cancel. pi raises ONE such request at
 * a time; it is surfaced in two places — the transcript `question-cell`
 * (QuestionCellView) and the composer-anchored panel (ComposerPendingUserInput) —
 * and BOTH answer the SAME request through our existing `ui_response`
 * pass-through. This is the one shared control surface both consume so the two
 * never drift; the only thing that varies is the `testidPrefix` (and each
 * caller's own outer container / heading).
 *
 * Answering calls `sendUiResponse(requestId, response)`; the server resolves the
 * request and emits `question_answered`, which marks the cell answered so both
 * surfaces drop out together.
 *
 * Single-answer guard: the SAME request renders in both surfaces at once, so a
 * per-component flag wouldn't cover a click on the composer panel AND the
 * transcript card during the answer round-trip. This module-scoped set of
 * already-answered request ids makes the send idempotent across every instance
 * and rapid double-clicks (the server also dedupes — this just avoids emitting
 * the wasted second `ui_response` at all). Ids are unique per pi request and the
 * cell drops out on `question_answered`, so the set stays turn-bounded.
 */
const answeredRequestIds = new Set<string>();

export function QuestionAnswerControls({
  question,
  testidPrefix,
}: {
  question: QuestionCell;
  testidPrefix: string;
}) {
  const [inputValue, setInputValue] = useState(
    question.method === "editor" ? (question.prefill ?? "") : "",
  );

  // Reset the draft when a NEW request takes the slot (pi emits one at a time).
  useEffect(() => {
    setInputValue(question.method === "editor" ? (question.prefill ?? "") : "");
  }, [question.requestId, question.method, question.prefill]);

  const answer = (response: Record<string, unknown>): void => {
    // Idempotent across both surfaces + double-clicks (see module doc).
    if (answeredRequestIds.has(question.requestId)) return;
    answeredRequestIds.add(question.requestId);
    sendUiResponse(question.requestId, response);
  };

  return (
    <>
      {question.method === "confirm" ? (
        <div className="mt-3 flex gap-2">
          <button
            type="button"
            data-testid={`${testidPrefix}-confirm-yes`}
            className="rounded-capsule bg-primary px-4 py-1.5 text-sm font-medium"
            style={{ color: "var(--color-accent-foreground)" }}
            onClick={() => answer({ confirmed: true })}
          >
            Yes
          </button>
          <button
            type="button"
            data-testid={`${testidPrefix}-confirm-no`}
            className="rounded-capsule border border-border-strong px-4 py-1.5 text-sm text-text-secondary"
            onClick={() => answer({ confirmed: false })}
          >
            No
          </button>
        </div>
      ) : question.method === "select" ? (
        <div className="mt-3 flex flex-wrap gap-2">
          {(question.options ?? []).map((option) => (
            <button
              key={option}
              type="button"
              data-testid={`${testidPrefix}-option-${option}`}
              className="rounded-capsule border border-border-strong px-3 py-1.5 text-sm text-text-primary hover:border-accent"
              onClick={() => answer({ value: option })}
            >
              {option}
            </button>
          ))}
        </div>
      ) : question.method === "editor" ? (
        <div className="mt-3 flex flex-col gap-2">
          <textarea
            data-testid={`${testidPrefix}-editor`}
            aria-label={question.title}
            className="min-h-[7rem] resize-y rounded-md border border-border-strong bg-surface px-2 py-1.5 font-mono text-sm text-text-primary outline-none focus:border-accent"
            placeholder={question.placeholder}
            value={inputValue}
            onChange={(event) => setInputValue(event.target.value)}
          />
          <button
            type="button"
            data-testid={`${testidPrefix}-submit`}
            className="self-end rounded-capsule bg-primary px-3 py-1.5 text-sm font-medium"
            style={{ color: "var(--color-accent-foreground)" }}
            onClick={() => answer({ value: inputValue })}
          >
            Send
          </button>
        </div>
      ) : (
        <div className="mt-3 flex gap-2">
          <input
            data-testid={`${testidPrefix}-input`}
            aria-label={question.title}
            className="flex-1 rounded-md border border-border-strong bg-surface px-2 py-1.5 text-sm text-text-primary outline-none focus:border-accent"
            placeholder={question.placeholder}
            value={inputValue}
            onChange={(event) => setInputValue(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") {
                event.preventDefault();
                answer({ value: inputValue });
              }
            }}
          />
          <button
            type="button"
            data-testid={`${testidPrefix}-submit`}
            className="rounded-capsule bg-primary px-3 py-1.5 text-sm font-medium"
            style={{ color: "var(--color-accent-foreground)" }}
            onClick={() => answer({ value: inputValue })}
          >
            Send
          </button>
        </div>
      )}
      <button
        type="button"
        className="mt-2 text-xs text-text-muted hover:text-text-primary"
        data-testid={`${testidPrefix}-cancel`}
        onClick={() => answer({ cancelled: true })}
      >
        Cancel
      </button>
    </>
  );
}
