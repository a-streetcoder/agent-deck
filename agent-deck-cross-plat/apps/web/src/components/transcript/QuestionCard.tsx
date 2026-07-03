import { forwardRef, type ReactNode } from "react";

import { cn } from "@/lib/cn";
import { MarkdownDocument } from "@/design-system/markdown/MarkdownDocument";
import type { MessageBubbleAttachment } from "./MessageBubble";

export interface QuestionCardProps {
  /** Stable transcript entry id; used by the navigation rail. */
  id: string;
  /** Question body (markdown). */
  text: string;
  /** Optional asker label (defaults to "You"). */
  askedBy?: string;
  /** Optional timestamp string. */
  timestamp?: string;
  /** Attachment chips. */
  attachments?: MessageBubbleAttachment[];
  /** Trailing slot (typically the copy button overlay). */
  trailing?: ReactNode;
  className?: string;
}

/**
 * QuestionCard — pinned-right user-question row that opens every
 * transcript thread. Mirrors `PiAgentNativeQuestionView` in geometry:
 * the row is hugged to its trailing edge, the bubble is rounded with a
 * tinted brand-accent fill, and the chip strip wraps under the header.
 *
 * Carries `data-entry-id` so QuestionNavigationRail can scroll to the
 * corresponding row by selector.
 */
export const QuestionCard = forwardRef<HTMLDivElement, QuestionCardProps>(function QuestionCard(
  { id, text, askedBy = "You", timestamp, attachments, trailing, className },
  ref,
) {
  return (
    <div
      ref={ref}
      data-testid="question-card"
      data-entry-id={id}
      className={cn(
        "rounded-xl border border-[var(--color-role-user)]/25",
        "bg-[var(--color-role-user)]/8",
        "px-4 py-3 flex flex-col gap-2",
        "text-[13px] leading-relaxed",
        className,
      )}
    >
      <div className="flex items-baseline justify-between gap-3">
        <span className="text-[11px] font-semibold uppercase tracking-wide text-[var(--color-role-user)]">
          {askedBy}
        </span>
        <span className="flex items-center gap-2 text-[11px] text-text-muted">
          {timestamp ? <span>{timestamp}</span> : null}
          {trailing}
        </span>
      </div>

      {attachments && attachments.length > 0 ? (
        <ul data-testid="question-card-attachments" className="flex flex-wrap gap-1.5">
          {attachments.map((attachment) => (
            <li
              key={attachment.id}
              data-kind={attachment.kind}
              className={cn(
                "inline-flex items-center gap-1 rounded-full border border-border-subtle bg-surface-elevated",
                "px-2 py-0.5 text-[11px] font-medium text-text-secondary",
              )}
            >
              {attachment.label}
            </li>
          ))}
        </ul>
      ) : null}

      <MarkdownDocument source={text} className="text-[13px]" />
    </div>
  );
});

export default QuestionCard;
