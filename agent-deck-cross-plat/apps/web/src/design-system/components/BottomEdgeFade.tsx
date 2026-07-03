import { forwardRef, type HTMLAttributes } from "react";
import { cn } from "../../lib/cn";

export interface BottomEdgeFadeProps extends Omit<HTMLAttributes<HTMLDivElement>, "children"> {
  /** Fade height in pixels. Defaults to 24. */
  height?: number;
}

/**
 * Absolutely-positioned strip painted with a linear gradient from
 * transparent (top) to `bg-surface` (bottom). Drop it inside the relative-
 * positioned scroll wrapper so the last list row visually fades out as
 * the viewport ends, mirroring `AppListBottomEdgeFade` in the macOS app.
 *
 * Purely presentational: marked `aria-hidden` and `pointer-events-none`
 * so it never traps clicks or assistive-tech focus.
 */
export const BottomEdgeFade = forwardRef<HTMLDivElement, BottomEdgeFadeProps>(
  function BottomEdgeFade({ height = 24, className, style, ...rest }, ref) {
    return (
      <div
        ref={ref}
        aria-hidden="true"
        className={cn("pointer-events-none absolute inset-x-0 bottom-0", className)}
        style={{
          height,
          backgroundImage: "linear-gradient(to bottom, transparent 0%, var(--color-surface) 100%)",
          ...style,
        }}
        {...rest}
      />
    );
  },
);

BottomEdgeFade.displayName = "BottomEdgeFade";

export default BottomEdgeFade;
