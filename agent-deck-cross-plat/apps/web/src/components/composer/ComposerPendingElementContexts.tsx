import { MousePointerClick, X } from "lucide-react";
import { cn } from "@/lib/cn";
import { formatElementContextLabel, type PendingElementContext } from "../../lib/elementContext.ts";

/**
 * Pending "preview element" cards above the composer (Slice 16), pattern-ported
 * from t3code's `chat/ComposerPendingElementContexts.tsx` (MIT) and styled to
 * match our S12 `ComposerPendingReviewComments` chips (our tokens, not their
 * atoms). Each card names the `<tag>` label, shows the user's note, and
 * dismisses with its X. Rendered inside the composer surface just above the text
 * editor; a card per pending context, wrapping. Unlike a review comment there is
 * no diff row to jump to, so the card is display + remove only.
 */

interface ComposerPendingElementContextsProps {
  contexts: readonly PendingElementContext[];
  onRemove: (contextId: string) => void;
  className?: string;
}

export function ComposerPendingElementContexts({
  contexts,
  onRemove,
  className,
}: ComposerPendingElementContextsProps) {
  if (contexts.length === 0) return null;

  return (
    <div
      className={cn("flex flex-wrap gap-1.5 px-3 pt-3", className)}
      data-testid="composer-pending-elements"
    >
      {contexts.map((context) => {
        const label = formatElementContextLabel(context);
        const detail = context.note.trim() || context.selector || context.pageUrl;
        return (
          <span
            key={context.id}
            data-testid="pending-element-card"
            data-selector={context.selector ?? ""}
            className="group flex max-w-full items-center gap-1.5 rounded-lg border border-border-strong bg-surface py-1 pl-2 pr-1 text-xs text-text-secondary"
            title={[label, context.selector, context.pageUrl, context.note.trim()]
              .filter((part): part is string => Boolean(part && part.length > 0))
              .join("\n")}
          >
            <MousePointerClick className="h-3.5 w-3.5 shrink-0 text-text-muted" aria-hidden />
            <span className="min-w-0 truncate font-mono text-[11px]">{label}</span>
            {detail ? (
              <span className="min-w-0 max-w-[28ch] truncate text-text-muted">{detail}</span>
            ) : null}
            <button
              type="button"
              aria-label={`Remove element context ${label}`}
              data-testid="pending-element-remove"
              className="shrink-0 rounded p-0.5 text-text-muted hover:bg-[var(--color-hover-fill)] hover:text-[var(--color-role-error)]"
              onClick={(event) => {
                event.preventDefault();
                event.stopPropagation();
                onRemove(context.id);
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
