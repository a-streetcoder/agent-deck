import { forwardRef, type HTMLAttributes, type ReactNode } from "react";
import { cn } from "../../lib/cn";

export interface ToolbarProps extends HTMLAttributes<HTMLDivElement> {
  /** Leading slot (typically navigation / back chevron). */
  leading?: ReactNode;
  /** Center slot (page title, segmented control). */
  center?: ReactNode;
  /** Trailing slot (action buttons). */
  trailing?: ReactNode;
  /** Render as a draggable Tauri title bar (data-tauri-drag-region). */
  draggable?: boolean;
  /** Disable the border-bottom hairline. */
  borderless?: boolean;
}

/**
 * Three-slot toolbar matching the macOS NSToolbar layout: leading group,
 * a center title slot, and a trailing actions group. Set `draggable` so the
 * Tauri title bar can be moved by clicking empty toolbar space.
 */
export const Toolbar = forwardRef<HTMLDivElement, ToolbarProps>(function Toolbar(
  { leading, center, trailing, draggable, borderless, className, ...rest },
  ref,
) {
  return (
    <div
      ref={ref}
      data-tauri-drag-region={draggable ? "" : undefined}
      className={cn(
        "flex h-[var(--space-section,18px)] min-h-12 w-full items-center gap-2 px-3",
        "bg-surface text-text-primary",
        !borderless && "border-b border-border-subtle",
        className,
      )}
      {...rest}
    >
      <div className="flex shrink-0 items-center gap-1">{leading}</div>
      <div className="flex flex-1 items-center justify-center gap-2 truncate">{center}</div>
      <div className="flex shrink-0 items-center gap-1">{trailing}</div>
    </div>
  );
});

export default Toolbar;
