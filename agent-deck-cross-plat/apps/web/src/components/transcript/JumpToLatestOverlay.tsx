import { ChevronDown } from "lucide-react";

import { cn } from "@/lib/cn";

/**
 * JumpToLatestOverlay — bottom-right pill that appears when the user
 * scrolls up away from the transcript bottom.
 *
 * Ports `JumpToLatestOverlay` + `JumpToLatestPill` from
 * `PiAgentViews.swift`. The overlay container is `absolute` so it never
 * occupies layout space; the pill itself is a 32x32 brand-accent glass
 * circle that calls `onJump` on click.
 *
 * The Swift version animates in from the bottom edge with a spring;
 * for the cross-platform port we use a CSS opacity + translate fade
 * driven by Tailwind's `transition-*` utilities.
 */
export interface JumpToLatestOverlayProps {
  /** True when the transcript is glued to its bottom edge. */
  isPinned: boolean;
  /** Click handler — parent scrolls the transcript to the latest row. */
  onJump: () => void;
  className?: string;
}

export function JumpToLatestOverlay({ isPinned, onJump, className }: JumpToLatestOverlayProps) {
  return (
    <div
      data-testid="jump-to-latest-overlay"
      data-state={isPinned ? "pinned" : "unpinned"}
      // Absolute so the overlay never flows the transcript and the pill
      // stays anchored to the bottom-right of the transcript region.
      className={cn("pointer-events-none absolute inset-0", className)}
    >
      {!isPinned ? (
        <button
          type="button"
          onClick={onJump}
          aria-label="Jump to latest message"
          title="Jump to latest"
          className={cn(
            // pointer-events-auto so the pill itself is clickable
            // while the outer overlay stays transparent to events.
            "pointer-events-auto absolute right-[22px] bottom-[14px]",
            "flex h-8 w-8 items-center justify-center rounded-full",
            "bg-[var(--color-primary)]/90 text-[color:var(--color-on-primary,#fff)]",
            "shadow-[0_8px_24px_-12px_rgba(0,0,0,0.25)]",
            "ring-1 ring-white/10",
            "transition-transform duration-150 ease-out",
            "hover:scale-[1.07] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary",
          )}
        >
          <ChevronDown size={14} strokeWidth={3} aria-hidden="true" />
        </button>
      ) : null}
    </div>
  );
}

export default JumpToLatestOverlay;
