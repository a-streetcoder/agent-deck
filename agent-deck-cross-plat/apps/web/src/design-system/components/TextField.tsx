import {
  forwardRef,
  useCallback,
  useId,
  useRef,
  type InputHTMLAttributes,
  type KeyboardEvent,
  type ReactNode,
} from "react";
import { cn } from "../../lib/cn";

export interface TextFieldProps extends Omit<InputHTMLAttributes<HTMLInputElement>, "size"> {
  label?: ReactNode;
  /** Description rendered below the input when there is no error. */
  description?: ReactNode;
  errorMessage?: ReactNode;
  /** Visual size: matches macOS controlSize small / regular / large. */
  size?: "sm" | "md" | "lg";
  leadingIcon?: ReactNode;
  trailingIcon?: ReactNode;
  /** Renders the field full-bleed across its container. */
  fullWidth?: boolean;
}

const sizeClasses: Record<NonNullable<TextFieldProps["size"]>, string> = {
  sm: "h-7 text-xs px-2",
  md: "h-8 text-sm px-2.5",
  lg: "h-10 text-sm px-3",
};

/**
 * Matches the macOS NSTextField look (DesignSystem.swift AppTextField):
 *   - 1px content stroke at rest, 2px brand-accent stroke on focus
 *   - 6pt corner radius
 *   - 8/5px padding
 *   - 0.55 opacity when disabled
 */
export const TextField = forwardRef<HTMLInputElement, TextFieldProps>(function TextField(
  {
    label,
    description,
    errorMessage,
    size = "md",
    leadingIcon,
    trailingIcon,
    fullWidth = true,
    className,
    id,
    disabled,
    onKeyDown,
    ...rest
  },
  ref,
) {
  const autoId = useId();
  const inputId = id ?? `tf-${autoId}`;
  const describedById = description ? `${inputId}-desc` : undefined;
  const errorId = errorMessage ? `${inputId}-err` : undefined;

  const inputRef = useRef<HTMLInputElement | null>(null);
  const setRefs = useCallback(
    (node: HTMLInputElement | null) => {
      inputRef.current = node;
      if (typeof ref === "function") {
        ref(node);
      } else if (ref) {
        (ref as { current: HTMLInputElement | null }).current = node;
      }
    },
    [ref],
  );

  const handleKeyDown = useCallback(
    (e: KeyboardEvent<HTMLInputElement>) => {
      if (e.key === "Escape") {
        inputRef.current?.blur();
      }
      onKeyDown?.(e);
    },
    [onKeyDown],
  );

  return (
    <div className={cn("flex flex-col gap-1", fullWidth && "w-full")}>
      {label ? (
        <label htmlFor={inputId} className="text-xs font-medium text-text-secondary">
          {label}
        </label>
      ) : null}

      <div
        className={cn(
          "group relative flex items-center gap-1.5",
          "rounded-sm border border-border-strong",
          "bg-surface-elevated text-text-primary",
          "transition-colors duration-150 ease-spring",
          "focus-within:border-primary",
          "focus-within:ring-2 focus-within:ring-primary/30",
          disabled && "opacity-55",
          errorMessage && "border-[var(--color-role-error,#E5746C)]",
          className,
        )}
      >
        {leadingIcon ? (
          <span className="pl-2 text-text-muted [&_svg]:h-3.5 [&_svg]:w-3.5">{leadingIcon}</span>
        ) : null}
        <input
          ref={setRefs}
          id={inputId}
          disabled={disabled}
          aria-describedby={describedById}
          aria-invalid={Boolean(errorMessage) || undefined}
          aria-errormessage={errorId}
          onKeyDown={handleKeyDown}
          className={cn(
            "min-w-0 flex-1 bg-transparent outline-none placeholder:text-text-muted",
            sizeClasses[size],
            leadingIcon && "pl-1",
            trailingIcon && "pr-1",
          )}
          {...rest}
        />
        {trailingIcon ? (
          <span className="pr-2 text-text-muted [&_svg]:h-3.5 [&_svg]:w-3.5">{trailingIcon}</span>
        ) : null}
      </div>

      {errorMessage ? (
        <p id={errorId} role="alert" className="text-xs text-[var(--color-role-error,#E5746C)]">
          {errorMessage}
        </p>
      ) : description ? (
        <p id={describedById} className="text-xs text-text-muted">
          {description}
        </p>
      ) : null}
    </div>
  );
});

export default TextField;
