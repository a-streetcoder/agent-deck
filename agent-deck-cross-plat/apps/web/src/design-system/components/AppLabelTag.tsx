import { forwardRef, type HTMLAttributes, type ReactNode } from "react";
import { cn } from "../../lib/cn";

export type AppLabelTagVariant = "default" | "success" | "warning" | "error" | "info" | "neutral";

export interface AppLabelTagProps extends HTMLAttributes<HTMLSpanElement> {
  variant?: AppLabelTagVariant;
  children: ReactNode;
}

/**
 * Status pill. Mirrors the macOS `AppLabelTag` (caption semibold expanded
 * width, 8pt h-pad / 4pt v-pad, 8pt corner radius, stroke at 55% of color,
 * text in the same hue).
 */
const variantClasses: Record<AppLabelTagVariant, string> = {
  default: cn("border-border-strong/55 text-text-primary", "bg-[var(--color-surface-subtle)]"),
  success: cn(
    "border-[var(--color-diff-added)]/55 text-[var(--color-diff-added)]",
    "bg-[var(--color-diff-added)]/10",
  ),
  warning: cn(
    "border-[var(--color-warning)]/55 text-[var(--color-warning)]",
    "bg-[var(--color-warning)]/10",
  ),
  error: cn(
    "border-[var(--color-role-error)]/55 text-[var(--color-role-error)]",
    "bg-[var(--color-role-error)]/10",
  ),
  info: cn(
    "border-[var(--color-brand-accent)]/55 text-[var(--color-brand-accent)]",
    "bg-[var(--color-brand-accent)]/10",
  ),
  neutral: cn("border-border-subtle text-text-muted", "bg-transparent"),
};

export const AppLabelTag = forwardRef<HTMLSpanElement, AppLabelTagProps>(function AppLabelTag(
  { variant = "default", className, children, ...rest },
  ref,
) {
  return (
    <span
      ref={ref}
      data-variant={variant}
      className={cn(
        "inline-flex items-center gap-1",
        "rounded-md border px-2 py-0.5",
        "text-xs font-semibold uppercase tracking-wide",
        "select-none whitespace-nowrap",
        variantClasses[variant],
        className,
      )}
      {...rest}
    >
      {children}
    </span>
  );
});

export default AppLabelTag;
