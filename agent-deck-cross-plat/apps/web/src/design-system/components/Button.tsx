import { forwardRef, type ButtonHTMLAttributes, type ReactNode } from "react";
import { cn } from "../../lib/cn";

/**
 * Visual variants. Mirrors the macOS app's AppPrimaryButtonStyle,
 * AppSecondaryButtonStyle, AppPillButtonStyle, plus a ghost (transparent)
 * and a destructive (role-error filled) variant.
 */
export type ButtonVariant = "primary" | "secondary" | "ghost" | "pill" | "destructive";

/** sm/md/lg map onto AppKit control sizes mini / small / regular. */
export type ButtonSize = "sm" | "md" | "lg";

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant;
  size?: ButtonSize;
  leadingIcon?: ReactNode;
  trailingIcon?: ReactNode;
  isLoading?: boolean;
  /** Stretches the button to fill its container. */
  fullWidth?: boolean;
  /**
   * Active-state styling used by the pill variant (mirrors
   * AppPillButtonStyle's `isActive`: brand-tinted glass + accent text).
   */
  isActive?: boolean;
}

const baseClasses = [
  "inline-flex items-center justify-center gap-1.5",
  "select-none whitespace-nowrap",
  "font-medium leading-none",
  "border transition-colors duration-150 ease-spring",
  "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-1 focus-visible:ring-offset-surface",
  "disabled:opacity-55 disabled:pointer-events-none",
].join(" ");

const sizeClasses: Record<ButtonSize, string> = {
  sm: "h-7 px-2.5 text-xs rounded-md",
  md: "h-8 px-3 text-sm rounded-md",
  lg: "h-10 px-4 text-sm rounded-lg",
};

/**
 * Variant chrome. Notes on the mapping:
 *
 * - `primary` — capsule background with a top-left → bottom-right gradient
 *   from brandAccentBright → brandAccent (`bg-primary` resolves to the
 *   active theme accent; the hover state simulates accent-bright by
 *   stepping to `bg-primary-hover`). Capsule shadow approximates
 *   `shadow(brandAccent@0.18, radius 5)` from AppPrimaryButtonStyle.
 * - `secondary` — glass capsule chrome via the secondary card tokens.
 * - `ghost` — transparent default with neutral hover wash.
 * - `pill` — translucent glass capsule that brightens with `isActive` to
 *   match AppPillButtonStyle's brandAccent-tint behaviour.
 * - `destructive` — solid role-error capsule (no equivalent in
 *   DesignSystem.swift; matches sheet-level Delete affordances).
 */
const variantClasses: Record<ButtonVariant, string> = {
  primary: cn(
    "border-transparent text-[var(--color-accent-foreground,#000)]",
    "bg-primary hover:bg-primary-hover active:opacity-86",
    "shadow-capsule",
  ),
  secondary: cn(
    "bg-surface-elevated text-text-primary",
    "border-border-strong hover:bg-[var(--color-hover-fill)]",
    "shadow-card",
  ),
  ghost: cn(
    "bg-transparent text-text-primary border-transparent",
    "hover:bg-[var(--color-hover-fill)]",
  ),
  pill: cn(
    "rounded-full border-transparent",
    "bg-surface-elevated/80 text-text-primary",
    "hover:bg-[var(--color-hover-fill)] active:opacity-75",
    "data-[active=true]:bg-primary/20 data-[active=true]:text-accent",
    "data-[active=true]:font-semibold",
  ),
  destructive: cn(
    "border-transparent text-white",
    "bg-[var(--color-role-error,#E5746C)] hover:opacity-90 active:opacity-80",
    "shadow-capsule",
  ),
};

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  {
    variant = "secondary",
    size = "md",
    leadingIcon,
    trailingIcon,
    isLoading = false,
    fullWidth = false,
    isActive = false,
    className,
    children,
    disabled,
    type = "button",
    ...rest
  },
  ref,
) {
  return (
    <button
      ref={ref}
      type={type}
      disabled={disabled || isLoading}
      aria-busy={isLoading || undefined}
      data-variant={variant}
      data-size={size}
      data-active={isActive ? "true" : undefined}
      className={cn(
        baseClasses,
        sizeClasses[size],
        variantClasses[variant],
        fullWidth && "w-full",
        className,
      )}
      {...rest}
    >
      {leadingIcon ? (
        <span className="-ml-0.5 flex shrink-0 items-center">{leadingIcon}</span>
      ) : null}
      <span className={cn(isLoading && "opacity-0")}>{children}</span>
      {trailingIcon && !isLoading ? (
        <span className="-mr-0.5 flex shrink-0 items-center">{trailingIcon}</span>
      ) : null}
      {isLoading ? (
        <span
          className="absolute h-3.5 w-3.5 animate-spin rounded-full border-2 border-current border-r-transparent"
          aria-hidden
        />
      ) : null}
    </button>
  );
});

export default Button;
