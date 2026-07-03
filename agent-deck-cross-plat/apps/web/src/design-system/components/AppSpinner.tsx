import { forwardRef, type HTMLAttributes } from "react";
import { cn } from "../../lib/cn";

/**
 * Five named sizes mirroring AppSpinner's macOS scale
 * (mini → extraLarge in the original; aliased to xs → xl here).
 */
export type AppSpinnerSize = "xs" | "sm" | "md" | "lg" | "xl";

export interface AppSpinnerProps extends Omit<HTMLAttributes<HTMLDivElement>, "aria-label"> {
  /** Defaults to "md" (18px) — matches macOS .regular. */
  size?: AppSpinnerSize;
  /** Accessible label announced to screen readers. Default: "Loading". */
  label?: string;
}

/**
 * Pixel dimensions per named size. Matches the macOS spinner table
 * (`tokens.ts → spinner.sizes`) so the React port and AppKit stay visually
 * aligned: mini 12 / small 14 / regular 18 / large 24 / extraLarge 30.
 */
const SIZE_PX: Record<AppSpinnerSize, number> = {
  xs: 12,
  sm: 14,
  md: 18,
  lg: 24,
  xl: 30,
};

/**
 * Stroke width is derived from the spinner diameter so the ring's relative
 * weight stays constant across sizes — matches `max(2, size*0.12)` in macOS.
 */
function strokeFor(px: number): number {
  return Math.max(2, Math.round(px * 0.12));
}

/**
 * Rotating brand-accent ring. Uses Tailwind's `animate-spin` keyframe
 * (1s linear infinite) instead of Framer Motion so it stays cheap and is
 * driven entirely by CSS — important inside frequently-mounted overlays
 * like LazyMarkdownCard placeholders.
 *
 * The trim arc (≈245°) is rendered via stroke-dasharray on a single
 * circle, sized via `2π·r * 0.68` to leave a transparent gap that gives
 * the ring its rotation cue.
 */
export const AppSpinner = forwardRef<HTMLDivElement, AppSpinnerProps>(function AppSpinner(
  { size = "md", label = "Loading", className, ...rest },
  ref,
) {
  const px = SIZE_PX[size];
  const stroke = strokeFor(px);
  // Radius leaves room for the stroke so it doesn't clip on the SVG box.
  const radius = (px - stroke) / 2;
  const circumference = 2 * Math.PI * radius;
  // Arc fraction matches macOS trim 0.18 → 0.86 (0.68 of the ring).
  const arcLength = circumference * 0.68;
  const gap = circumference - arcLength;

  return (
    <div
      ref={ref}
      role="progressbar"
      aria-label={label}
      aria-busy="true"
      className={cn("inline-flex items-center justify-center", className)}
      {...rest}
    >
      <svg
        width={px}
        height={px}
        viewBox={`0 0 ${px} ${px}`}
        fill="none"
        className="animate-spin text-accent"
        aria-hidden
      >
        <circle
          cx={px / 2}
          cy={px / 2}
          r={radius}
          stroke="currentColor"
          strokeWidth={stroke}
          strokeLinecap="round"
          strokeDasharray={`${arcLength} ${gap}`}
        />
      </svg>
    </div>
  );
});

AppSpinner.displayName = "AppSpinner";

export default AppSpinner;
