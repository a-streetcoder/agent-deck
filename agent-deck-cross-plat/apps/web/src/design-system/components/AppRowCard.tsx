import { forwardRef, type ButtonHTMLAttributes, type HTMLAttributes, type ReactNode } from "react";
import { cn } from "../../lib/cn";

export interface AppRowCardProps {
  /** Primary line; rendered with text-text-primary. */
  title: ReactNode;
  /** Optional second line; rendered muted. */
  subtitle?: ReactNode;
  /** Leading slot (typically a small icon or provider logo). */
  leading?: ReactNode;
  /** Trailing slot (chevron, badge, secondary action). */
  trailing?: ReactNode;
  /** Selected style + aria-selected="true". */
  selected?: boolean;
  /** Disabled state — when interactive, button is also disabled. */
  disabled?: boolean;
  /** Click handler. When provided, the row becomes a button. */
  onClick?: () => void;
  className?: string;
  /** Accessible name override; otherwise derived from title. */
  "aria-label"?: string;
}

const baseClasses = [
  "flex w-full items-center gap-3",
  "rounded-xl border border-border-subtle bg-surface-elevated",
  "px-3.5 py-2.5 text-left",
  "transition-colors duration-150 ease-spring",
].join(" ");

const interactiveClasses = [
  "cursor-pointer",
  "hover:bg-[var(--color-hover-fill)]",
  "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40",
  "disabled:cursor-not-allowed disabled:opacity-55",
  "aria-selected:border-[var(--color-selection-stroke)]",
  "aria-selected:bg-[var(--color-selection-fill)]",
].join(" ");

interface InnerProps {
  title: ReactNode;
  subtitle?: ReactNode;
  leading?: ReactNode;
  trailing?: ReactNode;
}

function RowInner({ title, subtitle, leading, trailing }: InnerProps) {
  return (
    <>
      {leading ? (
        <span className="flex h-7 w-7 shrink-0 items-center justify-center text-text-secondary">
          {leading}
        </span>
      ) : null}
      <span className="flex min-w-0 flex-1 flex-col gap-0.5">
        <span className="truncate text-sm font-semibold text-text-primary">{title}</span>
        {subtitle ? <span className="truncate text-xs text-text-muted">{subtitle}</span> : null}
      </span>
      {trailing ? (
        <span className="flex shrink-0 items-center gap-1 text-text-secondary">{trailing}</span>
      ) : null}
    </>
  );
}

/**
 * Clickable list-row variant of Card. Mirrors the macOS `AppRowCard`
 * primitive (cornerRadius 14, 14pt padding).
 *
 * When `onClick` is provided, renders a real `<button>` so keyboard
 * activation (Enter/Space) and focus rings come for free. Otherwise the
 * row renders as a non-interactive `<div>` with no role pollution.
 */
export const AppRowCard = forwardRef<HTMLElement, AppRowCardProps>(function AppRowCard(
  {
    title,
    subtitle,
    leading,
    trailing,
    selected = false,
    disabled = false,
    onClick,
    className,
    "aria-label": ariaLabel,
    ...rest
  },
  ref,
) {
  if (onClick) {
    const buttonProps: ButtonHTMLAttributes<HTMLButtonElement> = {
      type: "button",
      disabled,
      "aria-selected": selected,
      "aria-label": ariaLabel,
      onClick,
    };
    return (
      <button
        ref={ref as React.Ref<HTMLButtonElement>}
        className={cn(baseClasses, interactiveClasses, className)}
        {...buttonProps}
        {...(rest as ButtonHTMLAttributes<HTMLButtonElement>)}
      >
        <RowInner title={title} subtitle={subtitle} leading={leading} trailing={trailing} />
      </button>
    );
  }

  const divProps: HTMLAttributes<HTMLDivElement> = {
    "aria-label": ariaLabel,
  };
  return (
    <div
      ref={ref as React.Ref<HTMLDivElement>}
      className={cn(baseClasses, disabled && "opacity-55", className)}
      {...divProps}
      {...(rest as HTMLAttributes<HTMLDivElement>)}
    >
      <RowInner title={title} subtitle={subtitle} leading={leading} trailing={trailing} />
    </div>
  );
});

export default AppRowCard;
