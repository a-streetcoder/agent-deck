import { forwardRef, type HTMLAttributes } from "react";
import { cn } from "../../lib/cn";

export interface AppIndeterminateBarProps
  extends Omit<HTMLAttributes<HTMLDivElement>, "aria-label"> {
  /** Accessible label announced to screen readers. */
  label?: string;
  /** Track height; defaults to 3.5px to match macOS `AppIndeterminateBar`. */
  height?: number;
}

/**
 * Full-width track with a 42%-wide accent pill that sweeps left-to-right
 * on an infinite CSS keyframe. Used inside the initial-load overlay
 * (`AppInitialLoadOverlay` in the macOS port).
 *
 * Two-element composition:
 *  - track: `overflow-hidden` rounded surface with the subtle fill
 *  - pill: absolutely-positioned highlight driven by `animate-indeterminate-bar`
 */
export const AppIndeterminateBar = forwardRef<HTMLDivElement, AppIndeterminateBarProps>(
  function AppIndeterminateBar(
    { label = "Loading", height = 3.5, className, style, ...rest },
    ref,
  ) {
    return (
      <div
        ref={ref}
        role="progressbar"
        aria-busy="true"
        aria-label={label}
        data-indeterminate-track
        className={cn(
          "relative w-full overflow-hidden rounded-capsule",
          "bg-[var(--color-surface-subtle)]",
          className,
        )}
        style={{ height, ...style }}
        {...rest}
      >
        <div
          data-indeterminate-pill
          className={cn(
            "absolute inset-y-0 left-0 w-[42%] rounded-capsule",
            "bg-accent",
            "animate-indeterminate-bar",
          )}
        />
      </div>
    );
  },
);

AppIndeterminateBar.displayName = "AppIndeterminateBar";

export default AppIndeterminateBar;
