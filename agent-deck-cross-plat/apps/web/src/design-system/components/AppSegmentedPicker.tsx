import { forwardRef, useCallback, useId, useRef, type KeyboardEvent, type ReactNode } from "react";
import { cn } from "../../lib/cn";

export interface AppSegmentedOption<TValue extends string = string> {
  id: TValue;
  label: ReactNode;
  /** Optional leading icon rendered before the label. */
  icon?: ReactNode;
  /** Disable this segment (skipped during keyboard nav, not clickable). */
  disabled?: boolean;
  /** Accessible name override when the visible label is non-text. */
  "aria-label"?: string;
}

export type AppSegmentedPickerSize = "sm" | "md";

export interface AppSegmentedPickerProps<TValue extends string = string> {
  /** Ordered list of segments to render. */
  options: ReadonlyArray<AppSegmentedOption<TValue>>;
  /** Currently selected option id. */
  value: TValue;
  /** Fired with the option id when the user picks a new segment. */
  onChange: (next: TValue) => void;
  /** Visual size: matches macOS controlSize small / regular. */
  size?: AppSegmentedPickerSize;
  /** Disable the whole picker. */
  disabled?: boolean;
  /** Optional extra classes applied to the segmented track. */
  className?: string;
  /** Accessible name for the radio group. */
  "aria-label"?: string;
  /** Accessible labelledby reference (when the picker has a visible heading). */
  "aria-labelledby"?: string;
}

const sizeClasses: Record<AppSegmentedPickerSize, string> = {
  sm: "h-7 text-xs",
  md: "h-8 text-sm",
};

const segmentSizeClasses: Record<AppSegmentedPickerSize, string> = {
  sm: "px-2.5 gap-1",
  md: "px-3 gap-1.5",
};

/**
 * Pill segmented control. Mirrors the macOS `appSegmentedPicker` modifier
 * (`Picker.pickerStyle(.segmented)` + brand-accent tint):
 *
 *  - Selected segment renders with primary-accent background, white label
 *  - Unselected segments render transparent with muted text
 *  - Arrow keys roving-focus through enabled segments (skips disabled)
 *  - Home/End jump to first/last enabled segment
 *  - Wraps at edges
 */
function nextEnabledIndex<TValue extends string>(
  options: ReadonlyArray<AppSegmentedOption<TValue>>,
  start: number,
  direction: 1 | -1,
): number {
  const n = options.length;
  if (n === 0) return -1;
  for (let step = 1; step <= n; step += 1) {
    const idx = (((start + direction * step) % n) + n) % n;
    if (!options[idx]!.disabled) return idx;
  }
  return -1;
}

function firstEnabledIndex<TValue extends string>(
  options: ReadonlyArray<AppSegmentedOption<TValue>>,
): number {
  return options.findIndex((o) => !o.disabled);
}

function lastEnabledIndex<TValue extends string>(
  options: ReadonlyArray<AppSegmentedOption<TValue>>,
): number {
  for (let i = options.length - 1; i >= 0; i -= 1) {
    if (!options[i]!.disabled) return i;
  }
  return -1;
}

export const AppSegmentedPicker = forwardRef(function AppSegmentedPicker<
  TValue extends string = string,
>(
  {
    options,
    value,
    onChange,
    size = "md",
    disabled,
    className,
    "aria-label": ariaLabel,
    "aria-labelledby": ariaLabelledBy,
  }: AppSegmentedPickerProps<TValue>,
  ref: React.Ref<HTMLDivElement>,
) {
  const groupId = useId();
  const buttonRefs = useRef<Array<HTMLButtonElement | null>>([]);

  const moveTo = useCallback(
    (index: number) => {
      if (index < 0 || index >= options.length) return;
      const opt = options[index];
      if (!opt || opt.disabled) return;
      buttonRefs.current[index]?.focus();
      if (opt.id !== value) onChange(opt.id);
    },
    [options, onChange, value],
  );

  const handleKeyDown = useCallback(
    (event: KeyboardEvent<HTMLButtonElement>, index: number) => {
      switch (event.key) {
        case "ArrowRight":
        case "ArrowDown": {
          event.preventDefault();
          moveTo(nextEnabledIndex(options, index, 1));
          break;
        }
        case "ArrowLeft":
        case "ArrowUp": {
          event.preventDefault();
          moveTo(nextEnabledIndex(options, index, -1));
          break;
        }
        case "Home": {
          event.preventDefault();
          moveTo(firstEnabledIndex(options));
          break;
        }
        case "End": {
          event.preventDefault();
          moveTo(lastEnabledIndex(options));
          break;
        }
        default:
          break;
      }
    },
    [moveTo, options],
  );

  return (
    <div
      ref={ref}
      role="radiogroup"
      id={groupId}
      aria-label={ariaLabel}
      aria-labelledby={ariaLabelledBy}
      aria-disabled={disabled || undefined}
      className={cn(
        "inline-flex items-center gap-0.5 rounded-capsule border border-border-subtle",
        "bg-surface-elevated p-0.5",
        disabled && "opacity-55",
        sizeClasses[size],
        className,
      )}
    >
      {options.map((opt, index) => {
        const isSelected = opt.id === value;
        const isDisabled = Boolean(disabled || opt.disabled);
        return (
          <button
            key={opt.id}
            ref={(node) => {
              buttonRefs.current[index] = node;
            }}
            type="button"
            role="radio"
            aria-checked={isSelected}
            aria-label={opt["aria-label"]}
            data-selected={isSelected ? "true" : "false"}
            data-disabled={isDisabled ? "true" : "false"}
            disabled={isDisabled}
            // Roving tabindex: only the selected (or the first when nothing
            // is selected) segment is reachable via Tab.
            tabIndex={isSelected ? 0 : -1}
            onClick={() => {
              if (isDisabled) return;
              if (opt.id !== value) onChange(opt.id);
            }}
            onKeyDown={(event) => handleKeyDown(event, index)}
            className={cn(
              "inline-flex h-full shrink-0 items-center justify-center rounded-capsule",
              "whitespace-nowrap font-medium transition-colors duration-150 ease-spring",
              "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40",
              "disabled:cursor-not-allowed disabled:opacity-55",
              segmentSizeClasses[size],
              isSelected
                ? "bg-primary text-white shadow-capsule"
                : "bg-transparent text-text-muted hover:text-text-primary",
            )}
          >
            {opt.icon ? (
              <span className="flex shrink-0 items-center [&_svg]:h-3.5 [&_svg]:w-3.5">
                {opt.icon}
              </span>
            ) : null}
            <span className="truncate">{opt.label}</span>
          </button>
        );
      })}
    </div>
  );
}) as <TValue extends string = string>(
  props: AppSegmentedPickerProps<TValue> & { ref?: React.Ref<HTMLDivElement> },
) => React.JSX.Element;

export default AppSegmentedPicker;
