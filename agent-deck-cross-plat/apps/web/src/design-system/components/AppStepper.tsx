import {
  forwardRef,
  useCallback,
  useEffect,
  useId,
  useState,
  type ChangeEvent,
  type FocusEvent,
  type KeyboardEvent,
  type ReactNode,
} from "react";
import { Minus, Plus } from "lucide-react";
import { cn } from "../../lib/cn";

export interface AppStepperProps {
  /** Controlled numeric value. */
  value: number;
  /** Fired with the new (clamped) value when the user changes it. */
  onChange: (next: number) => void;
  /** Inclusive lower bound. */
  min: number;
  /** Inclusive upper bound. */
  max: number;
  /** Step increment (default 1). */
  step?: number;
  /** Optional visible label rendered above the control. */
  label?: ReactNode;
  /** Optional helper copy rendered under the label. */
  description?: ReactNode;
  /** Disable the whole control. */
  disabled?: boolean;
  /** Optional extra classes applied to the stepper root. */
  className?: string;
  /** Accessible name when there is no visible label. */
  "aria-label"?: string;
  /** Optional id for the underlying numeric input. */
  id?: string;
}

function clamp(value: number, min: number, max: number): number {
  if (Number.isNaN(value)) return min;
  if (value < min) return min;
  if (value > max) return max;
  return value;
}

/**
 * Numeric stepper with `-` / `+` buttons and a center input. Mirrors the
 * macOS `AppStepper`:
 *
 *  - Buttons increment / decrement by `step` and clamp at `min`/`max`
 *  - Buttons disable themselves at the bounds
 *  - Pressing ArrowUp / ArrowDown inside the input mirrors button presses
 *  - The input is uncommitted while editing; blur commits the parsed value
 *    (clamped). Unparseable input reverts to the last committed value.
 */
export const AppStepper = forwardRef<HTMLInputElement, AppStepperProps>(function AppStepper(
  {
    value,
    onChange,
    min,
    max,
    step = 1,
    label,
    description,
    disabled,
    className,
    "aria-label": ariaLabel,
    id,
  },
  ref,
) {
  const autoId = useId();
  const inputId = id ?? `stp-${autoId}`;
  const labelId = label ? `${inputId}-label` : undefined;

  // Local draft string so the user can clear, retype, etc. without each
  // keystroke firing onChange. Commit on blur / Enter.
  const [draft, setDraft] = useState<string>(String(value));
  useEffect(() => {
    setDraft(String(value));
  }, [value]);

  const atMin = value <= min;
  const atMax = value >= max;

  const commitDelta = useCallback(
    (delta: number) => {
      if (disabled) return;
      const next = clamp(value + delta, min, max);
      if (next === value) return;
      onChange(next);
    },
    [disabled, max, min, onChange, value],
  );

  const handleInputChange = useCallback((event: ChangeEvent<HTMLInputElement>) => {
    setDraft(event.target.value);
  }, []);

  const commitDraft = useCallback(() => {
    const trimmed = draft.trim();
    if (trimmed === "") {
      // Empty input reverts to the previous committed value.
      setDraft(String(value));
      return;
    }
    const parsed = Number(trimmed);
    if (!Number.isFinite(parsed)) {
      setDraft(String(value));
      return;
    }
    const next = clamp(parsed, min, max);
    if (next !== value) {
      onChange(next);
    } else {
      // Reformat the draft to the canonical clamped value (e.g. `4.` -> `4`).
      setDraft(String(next));
    }
  }, [draft, max, min, onChange, value]);

  const handleBlur = useCallback(
    (_event: FocusEvent<HTMLInputElement>) => {
      commitDraft();
    },
    [commitDraft],
  );

  const handleKeyDown = useCallback(
    (event: KeyboardEvent<HTMLInputElement>) => {
      if (event.key === "ArrowUp") {
        event.preventDefault();
        commitDelta(step);
      } else if (event.key === "ArrowDown") {
        event.preventDefault();
        commitDelta(-step);
      } else if (event.key === "Enter") {
        event.preventDefault();
        commitDraft();
      }
    },
    [commitDelta, commitDraft, step],
  );

  return (
    <div className={cn("inline-flex flex-col gap-1", disabled && "opacity-55", className)}>
      {label || description ? (
        <div className="flex min-w-0 flex-col gap-0.5">
          {label ? (
            <label id={labelId} htmlFor={inputId} className="text-sm text-text-primary">
              {label}
            </label>
          ) : null}
          {description ? <span className="text-xs text-text-muted">{description}</span> : null}
        </div>
      ) : null}
      <div
        className={cn(
          "inline-flex h-8 items-stretch gap-1 rounded-md border border-border-subtle",
          "bg-surface-elevated px-1 py-0.5",
        )}
      >
        <button
          type="button"
          aria-label="Decrement"
          disabled={disabled || atMin}
          onClick={() => commitDelta(-step)}
          className={cn(
            "inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-sm",
            "text-text-primary transition-colors duration-150 ease-spring",
            "hover:bg-[var(--color-hover-fill)]",
            "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40",
            "disabled:cursor-not-allowed disabled:text-text-muted disabled:hover:bg-transparent",
          )}
        >
          <Minus className="h-3 w-3" aria-hidden />
        </button>
        <input
          ref={ref}
          id={inputId}
          type="number"
          role="spinbutton"
          inputMode="numeric"
          value={draft}
          min={min}
          max={max}
          step={step}
          disabled={disabled}
          aria-label={!label ? ariaLabel : undefined}
          aria-labelledby={labelId}
          aria-valuenow={value}
          aria-valuemin={min}
          aria-valuemax={max}
          onChange={handleInputChange}
          onBlur={handleBlur}
          onKeyDown={handleKeyDown}
          className={cn(
            "w-16 min-w-0 bg-transparent text-center font-mono text-sm",
            "text-text-primary tabular-nums outline-none",
            "placeholder:text-text-muted",
            // Suppress the browser-rendered number spinners since we
            // provide our own buttons.
            "[appearance:textfield]",
            "[&::-webkit-outer-spin-button]:appearance-none",
            "[&::-webkit-inner-spin-button]:appearance-none",
            "disabled:cursor-not-allowed",
          )}
        />
        <button
          type="button"
          aria-label="Increment"
          disabled={disabled || atMax}
          onClick={() => commitDelta(step)}
          className={cn(
            "inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-sm",
            "text-text-primary transition-colors duration-150 ease-spring",
            "hover:bg-[var(--color-hover-fill)]",
            "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40",
            "disabled:cursor-not-allowed disabled:text-text-muted disabled:hover:bg-transparent",
          )}
        >
          <Plus className="h-3 w-3" aria-hidden />
        </button>
      </div>
    </div>
  );
});

export default AppStepper;
