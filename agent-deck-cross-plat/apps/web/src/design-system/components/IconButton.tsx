import { forwardRef, type ButtonHTMLAttributes, type ReactNode } from "react";
import { cn } from "../../lib/cn";

export type IconButtonVariant = "ghost" | "primary" | "secondary" | "destructive";
export type IconButtonSize = "sm" | "md" | "lg";

export interface IconButtonProps
  extends Omit<ButtonHTMLAttributes<HTMLButtonElement>, "aria-label"> {
  /** Required for accessibility; this button is icon-only. */
  "aria-label": string;
  /** lucide-react (or any) icon node. Sized via the className we apply. */
  icon: ReactNode;
  variant?: IconButtonVariant;
  size?: IconButtonSize;
  /** Render as a perfect circle. Defaults to a rounded square. */
  shape?: "square" | "circle";
}

const baseClasses = [
  "inline-flex items-center justify-center",
  "select-none transition-colors duration-150 ease-spring",
  "border focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-1 focus-visible:ring-offset-surface",
  "disabled:opacity-55 disabled:pointer-events-none",
].join(" ");

const sizeClasses: Record<IconButtonSize, string> = {
  sm: "h-6 w-6 [&_svg]:h-3.5 [&_svg]:w-3.5",
  md: "h-8 w-8 [&_svg]:h-4 [&_svg]:w-4",
  lg: "h-10 w-10 [&_svg]:h-5 [&_svg]:w-5",
};

const variantClasses: Record<IconButtonVariant, string> = {
  ghost: cn(
    "bg-transparent text-text-primary border-transparent",
    "hover:bg-[var(--color-hover-fill)]",
  ),
  secondary: cn(
    "bg-surface-elevated text-text-primary",
    "border-border-strong hover:bg-[var(--color-hover-fill)]",
  ),
  primary: cn(
    "bg-primary text-[var(--color-accent-foreground,#000)]",
    "border-transparent hover:bg-primary-hover",
  ),
  destructive: cn(
    "bg-[var(--color-role-error,#E5746C)] text-white",
    "border-transparent hover:opacity-90",
  ),
};

/**
 * Square (or circular) icon-only button. Designed to take a lucide-react icon
 * via the `icon` prop. Always requires `aria-label`.
 */
export const IconButton = forwardRef<HTMLButtonElement, IconButtonProps>(function IconButton(
  { icon, variant = "ghost", size = "md", shape = "square", className, type = "button", ...rest },
  ref,
) {
  return (
    <button
      ref={ref}
      type={type}
      className={cn(
        baseClasses,
        sizeClasses[size],
        variantClasses[variant],
        shape === "circle" ? "rounded-full" : "rounded-md",
        className,
      )}
      {...rest}
    >
      {icon}
    </button>
  );
});

export default IconButton;
