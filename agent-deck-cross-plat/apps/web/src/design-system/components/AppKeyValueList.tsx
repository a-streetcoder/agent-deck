import { forwardRef, type HTMLAttributes, type ReactNode } from "react";
import { Copy } from "lucide-react";
import { cn } from "../../lib/cn";

export interface AppKeyValueItem {
  /** Stable key used for React identity. Defaults to the label string. */
  id?: string;
  /** Left column label. */
  label: ReactNode;
  /** Right column value. Strings render plainly; ReactNodes pass through. */
  value: ReactNode;
  /**
   * When present, a copy button renders at the trailing edge of the row.
   * The value passed to `onCopy` is this string (not the display value).
   */
  copyValue?: string;
}

export interface AppKeyValueListProps extends Omit<HTMLAttributes<HTMLDListElement>, "onCopy"> {
  items: AppKeyValueItem[];
  /** Called when a row's copy button is activated. */
  onCopy?: (value: string, label: string) => void;
}

/**
 * Two-column key/value list. Matches the macOS `AppKeyValueList`:
 *  - definition-list semantics (`<dl>`, `<dt>`, `<dd>`)
 *  - 10pt vertical row spacing
 *  - labels in muted text, values in primary text
 *  - optional inline copy affordance per row
 *
 * When `items` is empty the component renders nothing so callers can use it
 * unconditionally without guarding for empty state.
 */
export const AppKeyValueList = forwardRef<HTMLDListElement, AppKeyValueListProps>(
  function AppKeyValueList({ items, onCopy, className, ...rest }, ref) {
    if (items.length === 0) return null;

    return (
      <dl
        ref={ref}
        className={cn(
          "grid grid-cols-[minmax(0,140px)_1fr] gap-x-4 gap-y-2.5",
          "text-sm",
          className,
        )}
        {...rest}
      >
        {items.map((item, index) => {
          const labelText = typeof item.label === "string" ? item.label : String(item.label);
          const key = item.id ?? labelText ?? index;
          return (
            <div key={key} className="contents" data-testid="app-kv-row">
              <dt className="truncate text-text-muted">{item.label}</dt>
              <dd className="m-0 flex min-w-0 items-start gap-2">
                <span className="min-w-0 flex-1 break-words text-text-primary">{item.value}</span>
                {item.copyValue !== undefined ? (
                  <button
                    type="button"
                    aria-label={`Copy ${labelText}`}
                    onClick={() => onCopy?.(item.copyValue!, labelText)}
                    className={cn(
                      "inline-flex h-6 w-6 shrink-0 items-center justify-center",
                      "rounded-md border border-border-subtle bg-surface-elevated text-text-secondary",
                      "transition-colors duration-150 ease-spring",
                      "hover:bg-[var(--color-hover-fill)]",
                      "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40",
                    )}
                  >
                    <Copy className="h-3.5 w-3.5" aria-hidden />
                  </button>
                ) : null}
              </dd>
            </div>
          );
        })}
      </dl>
    );
  },
);

export default AppKeyValueList;
