import { forwardRef, type HTMLAttributes, type ReactNode } from "react";
import { cn } from "../../lib/cn";

export type CardVariant = "surface" | "subtle" | "transparent";
export type CardPadding = "none" | "sm" | "md" | "lg";

// `title` on a div is normally a string (HTML title attribute) but we use
// it as a header slot for the Card. Omit the base prop so we can re-type it.
export interface CardProps extends Omit<HTMLAttributes<HTMLDivElement>, "title"> {
  variant?: CardVariant;
  padding?: CardPadding;
  /** Optional title rendered with a divider below the slot. */
  title?: ReactNode;
  /** Optional trailing slot in the header row. */
  headerTrailing?: ReactNode;
  /** Adds a soft shadow + lift. */
  elevated?: boolean;
  asChild?: false;
}

const variantClasses: Record<CardVariant, string> = {
  surface: cn("bg-surface-elevated text-text-primary", "border border-border-subtle"),
  subtle: cn("bg-[var(--color-surface-subtle)] text-text-primary", "border border-border-subtle"),
  transparent: "bg-transparent text-text-primary border border-transparent",
};

const paddingClasses: Record<CardPadding, string> = {
  none: "p-0",
  sm: "p-3",
  md: "p-4",
  lg: "p-[var(--space-section,18px)]",
};

/**
 * Generic content surface. Matches the macOS AppCard primitive
 * (cornerRadius 12, 1px hairline stroke, 18pt padding by default).
 */
export const Card = forwardRef<HTMLDivElement, CardProps>(function Card(
  {
    variant = "surface",
    padding = "md",
    title,
    headerTrailing,
    elevated = false,
    className,
    children,
    ...rest
  },
  ref,
) {
  const hasHeader = Boolean(title || headerTrailing);
  return (
    <div
      ref={ref}
      className={cn(
        "rounded-lg",
        variantClasses[variant],
        elevated && "shadow-card",
        // padding lives on the inner so the header can span edge-to-edge.
        className,
      )}
      {...rest}
    >
      {hasHeader ? (
        <div
          className={cn(
            "flex items-center justify-between gap-2",
            paddingClasses[padding === "none" ? "sm" : padding],
            "border-b border-border-subtle",
          )}
        >
          <div className="min-w-0 text-sm font-semibold text-text-primary">{title}</div>
          {headerTrailing ? (
            <div className="flex shrink-0 items-center gap-1">{headerTrailing}</div>
          ) : null}
        </div>
      ) : null}
      <div className={cn(hasHeader ? paddingClasses[padding] : paddingClasses[padding])}>
        {children}
      </div>
    </div>
  );
});

export default Card;
