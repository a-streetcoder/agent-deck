import {
  forwardRef,
  useCallback,
  useEffect,
  useRef,
  useState,
  type ButtonHTMLAttributes,
} from "react";
import { Check, Copy } from "lucide-react";
import { cn } from "../../lib/cn";

/** How long the success glyph stays before reverting to the idle copy icon. */
const COPIED_RESET_MS = 1100;

export interface AppCopyButtonProps
  extends Omit<ButtonHTMLAttributes<HTMLButtonElement>, "aria-label" | "children"> {
  /** Text to write to the clipboard. */
  text: string;
  /**
   * Optional override for the idle label. Defaults to `"Copy"` and is
   * swapped to `"Copied"` for `COPIED_RESET_MS` after a successful write.
   */
  "aria-label"?: string;
  /** Optional label to use while in the copied state (defaults to `"Copied"`). */
  copiedLabel?: string;
  /** Hooks for parent telemetry. */
  onCopySuccess?: () => void;
  onCopyError?: (err: unknown) => void;
}

type CopyState = "idle" | "copied";

/**
 * Icon button that copies `text` to the clipboard via
 * `navigator.clipboard.writeText` and shows a checkmark glyph for
 * `COPIED_RESET_MS` after success. Matches macOS `AppCopyIconButton`.
 *
 * Failures (clipboard denied, missing API) leave the button in the idle
 * state so the user can try again; an optional `onCopyError` hook lets the
 * host log the failure.
 */
export const AppCopyButton = forwardRef<HTMLButtonElement, AppCopyButtonProps>(
  function AppCopyButton(
    {
      text,
      "aria-label": ariaLabel,
      copiedLabel = "Copied",
      onCopySuccess,
      onCopyError,
      className,
      type = "button",
      title,
      ...rest
    },
    ref,
  ) {
    const [state, setState] = useState<CopyState>("idle");
    const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

    useEffect(
      () => () => {
        if (timerRef.current) clearTimeout(timerRef.current);
      },
      [],
    );

    const handleClick = useCallback(async () => {
      try {
        await navigator.clipboard.writeText(text);
        setState("copied");
        if (timerRef.current) clearTimeout(timerRef.current);
        timerRef.current = setTimeout(() => {
          setState("idle");
          timerRef.current = null;
        }, COPIED_RESET_MS);
        onCopySuccess?.();
      } catch (err) {
        onCopyError?.(err);
      }
    }, [text, onCopySuccess, onCopyError]);

    const label = state === "copied" ? copiedLabel : (ariaLabel ?? "Copy");

    return (
      <button
        ref={ref}
        type={type}
        aria-label={label}
        title={title ?? label}
        data-state={state}
        onClick={handleClick}
        className={cn(
          "inline-flex h-7 w-7 items-center justify-center rounded-full",
          "border border-border-subtle bg-surface-elevated text-text-muted",
          "transition-colors duration-150 ease-spring",
          "hover:bg-[var(--color-hover-fill)] hover:text-text-primary",
          "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40",
          "disabled:opacity-55 disabled:pointer-events-none",
          state === "copied" && "text-accent",
          className,
        )}
        {...rest}
      >
        {state === "copied" ? (
          <Check className="h-3.5 w-3.5" aria-hidden />
        ) : (
          <Copy className="h-3.5 w-3.5" aria-hidden />
        )}
      </button>
    );
  },
);

export default AppCopyButton;
