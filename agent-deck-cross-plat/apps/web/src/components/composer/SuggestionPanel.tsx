import { useEffect } from "react";

/**
 * A shared keyboard-drivable suggestion list for the composer's `/` and `@`
 * panels (native SlashSuggestionPanel / FileAtSuggestionPanel). Selection is
 * owned by the parent so the textarea's key handler can drive it.
 */

export interface SuggestionItem {
  id: string;
  label: string;
  detail?: string;
}

export function SuggestionPanel({
  items,
  selectedIndex,
  onHover,
  onAccept,
  testid,
}: {
  items: SuggestionItem[];
  selectedIndex: number;
  onHover: (index: number) => void;
  onAccept: (item: SuggestionItem) => void;
  testid: string;
}) {
  // Keep the selected row in view as the user arrows through.
  useEffect(() => {
    document
      .querySelector(`[data-suggestion-index="${selectedIndex}"]`)
      ?.scrollIntoView({ block: "nearest" });
  }, [selectedIndex]);

  if (items.length === 0) return null;

  return (
    <div
      data-testid={testid}
      role="listbox"
      className="absolute bottom-full left-3 z-20 mb-1 max-h-56 w-[min(28rem,90%)] overflow-y-auto rounded-xl border border-border-strong bg-surface-elevated p-1 shadow-elevated"
    >
      {items.map((item, index) => (
        <button
          key={item.id}
          data-suggestion-index={index}
          data-testid={`${testid}-item-${item.id}`}
          role="option"
          aria-selected={index === selectedIndex}
          className={`flex w-full items-baseline gap-2 rounded-md px-2 py-1 text-left text-sm ${
            index === selectedIndex
              ? "bg-[var(--color-selection-fill)] text-text-primary"
              : "text-text-secondary hover:bg-[var(--color-hover-fill)]"
          }`}
          onMouseEnter={() => onHover(index)}
          onMouseDown={(event) => {
            event.preventDefault(); // keep textarea focus
            onAccept(item);
          }}
        >
          <span className="shrink-0 font-mono">{item.label}</span>
          {item.detail ? (
            <span className="min-w-0 truncate text-xs text-text-muted">{item.detail}</span>
          ) : null}
        </button>
      ))}
    </div>
  );
}
