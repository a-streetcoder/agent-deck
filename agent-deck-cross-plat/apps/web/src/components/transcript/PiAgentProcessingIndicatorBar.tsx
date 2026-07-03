import { cn } from "@/lib/cn";
import { AppIndeterminateBar } from "@/design-system/components/AppIndeterminateBar";

/**
 * PiAgentProcessingIndicatorBar — slim status row between transcript
 * and composer.
 *
 * Ports `PiAgentProcessingIndicatorBar` from `PiAgentViews.swift`:
 * surfaces the live runner activity ("Thinking…", "Calling tool",
 * "Compacting context", …) and collapses to zero visible height when
 * the runner is idle so the gap between transcript and composer stays
 * stable.
 *
 * The bar is driven by `sessionsSlice.processingMessageBySession[sid]`
 * via the parent screen — this component itself is presentational.
 */
export interface PiAgentProcessingIndicatorBarProps {
  /** Status message; null/empty collapses the bar to idle. */
  message: string | null;
  /** Optional session id mirrored as a data attribute for tests. */
  sessionId?: string;
  className?: string;
}

export function PiAgentProcessingIndicatorBar({
  message,
  sessionId,
  className,
}: PiAgentProcessingIndicatorBarProps) {
  const trimmed = (message ?? "").trim();
  const isActive = trimmed.length > 0;

  return (
    <div
      data-testid="pi-processing-indicator"
      data-state={isActive ? "active" : "idle"}
      data-session-id={sessionId}
      aria-live="polite"
      className={cn(
        "transition-[height,opacity] duration-100 ease-out",
        isActive
          ? "flex w-full items-center gap-3 px-[18px] py-2 border-b border-border-subtle bg-surface"
          : "h-0 overflow-hidden opacity-0",
        className,
      )}
      style={isActive ? undefined : { height: 0 }}
    >
      {isActive ? (
        <>
          <span className="text-[12px] font-medium text-text-secondary truncate">{trimmed}</span>
          <div className="flex-1 min-w-0">
            <AppIndeterminateBar label={trimmed} height={3} />
          </div>
        </>
      ) : null}
    </div>
  );
}

export default PiAgentProcessingIndicatorBar;
