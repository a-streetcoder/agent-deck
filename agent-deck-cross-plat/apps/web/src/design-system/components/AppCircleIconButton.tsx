import { forwardRef, type ButtonHTMLAttributes, type ReactNode } from "react";
import { cn } from "../../lib/cn";

/**
 * Visual style of the circle icon button. Mirrors macOS
 * `AppCircleIconButtonStyle`:
 *
 *  - `soft`      → translucent brand-accent glass + accent foreground
 *                  (the default; matches the toolbar's primary affordances)
 *  - `prominent` → opaque brand-accent fill + accent-foreground glyph
 *                  (sheet headers, splash CTAs)
 *  - `neutral`   → bare regular glass with mutedText glyph
 *                  (incidental affordances)
 */
export type AppCircleIconButtonAppearance = "soft" | "prominent" | "neutral";

export type AppCircleIconButtonSize = "sm" | "md" | "lg";

export interface AppCircleIconButtonProps
  extends Omit<ButtonHTMLAttributes<HTMLButtonElement>, "aria-label"> {
  /** Required — this button is icon-only. */
  "aria-label": string;
  /** lucide-react (or any) icon node. Sized via the className we apply. */
  icon: ReactNode;
  appearance?: AppCircleIconButtonAppearance;
  size?: AppCircleIconButtonSize;
  /**
   * Optional tooltip text. Rendered as a `title` attribute until the
   * shared Tooltip primitive lands; will be migrated to Radix Tooltip
   * later without changing this API.
   */
  tooltip?: string;
}

const sizeClasses: Record<AppCircleIconButtonSize, string> = {
  sm: "h-6 w-6 [&_svg]:h-3 [&_svg]:w-3",
  md: "h-[30px] w-[30px] [&_svg]:h-4 [&_svg]:w-4",
  lg: "h-9 w-9 [&_svg]:h-5 [&_svg]:w-5",
};

const appearanceClasses: Record<AppCircleIconButtonAppearance, string> = {
  soft: cn("bg-primary/20 text-accent", "border-transparent hover:bg-primary/30"),
  prominent: cn(
    "bg-primary text-[var(--color-accent-foreground,#000)]",
    "border-transparent hover:bg-primary-hover",
  ),
  neutral: cn(
    "bg-surface-elevated text-text-muted",
    "border-border-subtle hover:bg-[var(--color-hover-fill)]",
  ),
};

const baseClasses = [
  "inline-flex items-center justify-center rounded-full border",
  "select-none transition-colors duration-150 ease-spring",
  "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-1 focus-visible:ring-offset-surface",
  "disabled:opacity-55 disabled:pointer-events-none",
].join(" ");

/**
 * Circular icon-only button matching macOS `AppCircleIconButton`. The hit
 * area is a perfect circle (rounded-full) so the focus ring and pointer
 * hit-test agree with the visible chrome.
 */
export const AppCircleIconButton = forwardRef<HTMLButtonElement, AppCircleIconButtonProps>(
  function AppCircleIconButton(
    { icon, appearance = "soft", size = "md", tooltip, className, type = "button", title, ...rest },
    ref,
  ) {
    return (
      <button
        ref={ref}
        type={type}
        title={tooltip ?? title}
        data-style={appearance}
        data-size={size}
        className={cn(baseClasses, sizeClasses[size], appearanceClasses[appearance], className)}
        {...rest}
      >
        {icon}
      </button>
    );
  },
);

export default AppCircleIconButton;
