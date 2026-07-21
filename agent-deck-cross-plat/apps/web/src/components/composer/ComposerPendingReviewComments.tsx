import { MessageSquare, X } from "lucide-react";
import { cn } from "@/lib/cn";
import type { PendingReviewComment } from "../../lib/reviewComments.ts";

/**
 * Pending review-comment cards above the composer (Slice 12), pattern-ported
 * from t3code's `chat/ComposerPendingReviewComments.tsx` (MIT). Each card names
 * the anchored `file rangeLabel`, shows the comment body, jumps to the diff row
 * on click, and dismisses with its X. Rendered inside the composer surface just
 * above the text editor; a card per pending comment, wrapping. Their styling
 * rides our tokens (the donor's inline-chip classes) rather than their atoms.
 */

interface ComposerPendingReviewCommentsProps {
  comments: readonly PendingReviewComment[];
  onRemove: (commentId: string) => void;
  onJump: (comment: PendingReviewComment) => void;
  className?: string;
}

export function ComposerPendingReviewComments({
  comments,
  onRemove,
  onJump,
  className,
}: ComposerPendingReviewCommentsProps) {
  if (comments.length === 0) return null;

  return (
    <div
      className={cn("flex flex-wrap gap-1.5 px-3 pt-3", className)}
      data-testid="composer-pending-comments"
    >
      {comments.map((comment) => {
        const label = `${comment.filePath} ${comment.rangeLabel}`;
        return (
          <span
            key={comment.id}
            role="button"
            tabIndex={0}
            data-testid="pending-comment-card"
            data-path={comment.filePath}
            className="group flex max-w-full cursor-pointer items-center gap-1.5 rounded-lg border border-border-strong bg-surface py-1 pl-2 pr-1 text-xs text-text-secondary transition-colors hover:border-accent/40 hover:text-text-primary"
            title={`${label}\n${comment.text}`}
            onClick={() => onJump(comment)}
            onKeyDown={(event) => {
              if (event.target !== event.currentTarget) return;
              if (event.key === "Enter" || event.key === " ") {
                event.preventDefault();
                onJump(comment);
              }
            }}
          >
            <MessageSquare className="h-3.5 w-3.5 shrink-0 text-text-muted" aria-hidden />
            <span className="min-w-0 truncate font-mono text-[11px]">{label}</span>
            <button
              type="button"
              aria-label={`Remove comment on ${label}`}
              data-testid="pending-comment-remove"
              className="shrink-0 rounded p-0.5 text-text-muted hover:bg-[var(--color-hover-fill)] hover:text-[var(--color-role-error)]"
              onClick={(event) => {
                event.preventDefault();
                event.stopPropagation();
                onRemove(comment.id);
              }}
            >
              <X className="h-3 w-3" aria-hidden />
            </button>
          </span>
        );
      })}
    </div>
  );
}
