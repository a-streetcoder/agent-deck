import { forwardRef, type HTMLAttributes, type ReactNode } from "react";
import { cn } from "../../lib/cn";
import { Button, type ButtonVariant } from "./Button";

export type AppEmptyStateLayout = "compact" | "fill";

export interface AppEmptyStateAction {
  label: ReactNode;
  onClick: () => void;
  variant?: ButtonVariant;
}

export interface AppEmptyStateProps extends HTMLAttributes<HTMLDivElement> {
  /** Required headline (e.g. "No sessions yet"). */
  heading: ReactNode;
  /** Optional supporting copy. */
  body?: ReactNode;
  /** Optional icon node (typically lucide-react). */
  icon?: ReactNode;
  /** Primary call-to-action rendered via the Button primitive. */
  action?: AppEmptyStateAction;
  /**
   * compact = intrinsic height with vertical padding.
   * fill = grow to fill the parent (use inside split views).
   */
  layout?: AppEmptyStateLayout;
}

/**
 * Centered empty-state placeholder. Used by sidebar lists, settings panes,
 * Doctor, and the chat transcript when there's nothing yet to show.
 *
 * The component conveys a passive update to assistive tech via
 * `role="status"` (no aria-live escalation — placeholders should not steal
 * focus).
 */
export const AppEmptyState = forwardRef<HTMLDivElement, AppEmptyStateProps>(function AppEmptyState(
  { heading, body, icon, action, layout = "compact", className, ...rest },
  ref,
) {
  return (
    <div
      ref={ref}
      role="status"
      data-layout={layout}
      className={cn(
        "flex w-full flex-col items-center justify-center gap-3 text-center",
        "px-6",
        layout === "compact" ? "py-3" : "h-full py-0",
        className,
      )}
      {...rest}
    >
      {icon ? (
        <div className="flex h-10 w-10 items-center justify-center text-text-muted">{icon}</div>
      ) : null}
      <div className="flex flex-col gap-1">
        <div className="text-sm font-semibold text-text-primary">{heading}</div>
        {body ? <div className="text-sm text-text-muted">{body}</div> : null}
      </div>
      {action ? (
        <Button variant={action.variant ?? "primary"} onClick={action.onClick} size="sm">
          {action.label}
        </Button>
      ) : null}
    </div>
  );
});

export default AppEmptyState;
