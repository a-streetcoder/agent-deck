import {
  useCallback,
  useId,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type MouseEvent,
  type ReactNode,
} from "react";
import { cn } from "../../lib/cn";

export interface AppListSection<T> {
  /** Stable section id. */
  id: string;
  /** Optional title rendered as a small-caps muted header. */
  title?: ReactNode;
  /** Optional custom header (replaces title chrome entirely). */
  header?: ReactNode;
  /** Optional footer block beneath the rows. */
  footer?: ReactNode;
  /** Optional empty-state line when items is empty. */
  emptyMessage?: ReactNode;
  /** Items rendered in declared order. */
  items: T[];
}

export type AppListSelectionMode = "single" | "multi";

export interface AppListProps<T> {
  sections: AppListSection<T>[];
  getId: (item: T) => string;
  renderItem: (item: T, isSelected: boolean) => ReactNode;
  /** Currently selected ids. */
  selectedIds?: string[];
  /** Fired whenever the selection changes. */
  onSelectionChange?: (ids: string[]) => void;
  /** Fired when Enter is pressed on a focused row. */
  onActivate?: (id: string) => void;
  selectionMode?: AppListSelectionMode;
  /** Optional per-item disabled predicate (disabled rows are skipped by arrow nav). */
  isDisabled?: (item: T) => boolean;
  /** Accessible name for the listbox. */
  ariaLabel?: string;
  className?: string;
}

interface FlatEntry<T> {
  id: string;
  item: T;
  sectionId: string;
  disabled: boolean;
}

function flatten<T>(
  sections: AppListSection<T>[],
  getId: (item: T) => string,
  isDisabled?: (item: T) => boolean,
): FlatEntry<T>[] {
  const out: FlatEntry<T>[] = [];
  for (const section of sections) {
    for (const item of section.items) {
      out.push({
        id: getId(item),
        item,
        sectionId: section.id,
        disabled: isDisabled?.(item) ?? false,
      });
    }
  }
  return out;
}

function rangeIds<T>(flat: FlatEntry<T>[], from: string, to: string): string[] {
  const fromIdx = flat.findIndex((e) => e.id === from);
  const toIdx = flat.findIndex((e) => e.id === to);
  if (fromIdx === -1 || toIdx === -1) return [to];
  const [lo, hi] = fromIdx <= toIdx ? [fromIdx, toIdx] : [toIdx, fromIdx];
  return flat
    .slice(lo, hi + 1)
    .filter((e) => !e.disabled)
    .map((e) => e.id);
}

function nextNavigable<T>(
  flat: FlatEntry<T>[],
  fromId: string | undefined,
  delta: 1 | -1,
): string | undefined {
  const navigable = flat.filter((e) => !e.disabled);
  if (navigable.length === 0) return undefined;
  if (fromId === undefined) {
    return delta === 1 ? navigable[0]?.id : navigable[navigable.length - 1]?.id;
  }
  const idx = navigable.findIndex((e) => e.id === fromId);
  if (idx === -1) {
    return delta === 1 ? navigable[0]?.id : navigable[navigable.length - 1]?.id;
  }
  // Wrap at the ends.
  const len = navigable.length;
  const nextIdx = (idx + delta + len) % len;
  return navigable[nextIdx]?.id;
}

/**
 * Sectioned, selectable list. Mirrors the macOS `AppList`:
 *  - listbox semantics (sections expose `role="group"` for screen readers)
 *  - single or multi-select (Cmd toggles, Shift extends a range from anchor)
 *  - arrow-key navigation with wrap-around, Enter to activate
 *  - selection styling driven by the brand accent token, not OS accent
 */
export function AppList<T>({
  sections,
  getId,
  renderItem,
  selectedIds = [],
  onSelectionChange,
  onActivate,
  selectionMode = "single",
  isDisabled,
  ariaLabel,
  className,
}: AppListProps<T>) {
  const listId = useId();
  const ulRef = useRef<HTMLUListElement>(null);
  const [anchorId, setAnchorId] = useState<string | undefined>(selectedIds[0]);
  const anchorRef = useRef(anchorId);
  anchorRef.current = anchorId;

  const flat = useMemo(() => flatten(sections, getId, isDisabled), [sections, getId, isDisabled]);
  const selectedSet = useMemo(() => new Set(selectedIds), [selectedIds]);

  const commit = useCallback(
    (next: string[], nextAnchor: string | undefined) => {
      setAnchorId(nextAnchor);
      onSelectionChange?.(next);
    },
    [onSelectionChange],
  );

  const handleSelect = useCallback(
    (id: string, event: MouseEvent<HTMLElement>) => {
      const entry = flat.find((e) => e.id === id);
      if (!entry || entry.disabled) return;

      if (selectionMode === "multi") {
        if (event.shiftKey) {
          const range = rangeIds(flat, anchorRef.current ?? id, id);
          commit(range, anchorRef.current ?? id);
          // Mirror SwiftUI's List(selection:) — once a row is committed the
          // container takes focus so arrow-key nav resumes immediately.
          ulRef.current?.focus();
          return;
        }
        if (event.metaKey || event.ctrlKey) {
          const next = new Set(selectedSet);
          if (next.has(id)) next.delete(id);
          else next.add(id);
          commit(
            flat.filter((e) => next.has(e.id)).map((e) => e.id),
            id,
          );
          ulRef.current?.focus();
          return;
        }
      }

      commit([id], id);
      ulRef.current?.focus();
    },
    [commit, flat, selectedSet, selectionMode],
  );

  const handleKeyDown = useCallback(
    (event: KeyboardEvent<HTMLUListElement>) => {
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        const cursor = anchorRef.current ?? selectedIds[0];
        const next = nextNavigable(flat, cursor, event.key === "ArrowDown" ? 1 : -1);
        if (next) commit([next], next);
        return;
      }
      if (event.key === "Enter") {
        event.preventDefault();
        const target = anchorRef.current ?? selectedIds[0];
        if (target) onActivate?.(target);
      }
    },
    [commit, flat, onActivate, selectedIds],
  );

  return (
    <ul
      ref={ulRef}
      id={listId}
      role="listbox"
      aria-label={ariaLabel}
      aria-multiselectable={selectionMode === "multi"}
      tabIndex={0}
      onKeyDown={handleKeyDown}
      className={cn(
        "flex flex-col gap-3 outline-none",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40",
        className,
      )}
    >
      {sections.map((section) => {
        const groupId = `${listId}-${section.id}`;
        const labelId = section.title ? `${groupId}-label` : undefined;
        return (
          <li key={section.id} className="list-none">
            <div role="group" aria-labelledby={labelId}>
              {section.header ??
                (section.title ? (
                  <div
                    id={labelId}
                    className={cn(
                      "px-2 pb-1 pt-2",
                      "text-[10px] font-semibold uppercase tracking-wider text-text-muted",
                    )}
                  >
                    {section.title}
                  </div>
                ) : null)}
              <ul className="m-0 flex flex-col gap-0.5 p-0">
                {section.items.length === 0 && section.emptyMessage ? (
                  // SwiftUI parity: the empty-state row uses
                  // `verticalPadding + 2` (≈ `py-2`), giving it a touch more
                  // breathing room than the regular `py-1.5` rows.
                  <li role="presentation" className="px-2 py-2 text-sm text-text-muted">
                    {section.emptyMessage}
                  </li>
                ) : null}
                {section.items.map((item) => {
                  const id = getId(item);
                  const disabled = isDisabled?.(item) ?? false;
                  const isSelected = selectedSet.has(id);
                  return (
                    <li
                      key={id}
                      role="option"
                      aria-selected={isSelected}
                      aria-disabled={disabled || undefined}
                      data-disabled={disabled || undefined}
                      data-row-bg
                      onClick={(event) => {
                        if (disabled) return;
                        handleSelect(id, event);
                      }}
                      className={cn(
                        "cursor-pointer select-none rounded-md px-2 py-1.5 text-sm",
                        // SwiftUI-parity: hover / selection fill swaps instantly
                        // (no transition), matching the native List highlight.
                        "transition-none",
                        "hover:bg-[var(--color-hover-fill)]",
                        isSelected && "bg-[var(--color-selection-fill)] text-text-primary",
                        disabled && "cursor-not-allowed opacity-55",
                      )}
                    >
                      {renderItem(item, isSelected)}
                    </li>
                  );
                })}
              </ul>
              {section.footer ? (
                <div className="px-2 pt-1 text-xs text-text-muted">{section.footer}</div>
              ) : null}
            </div>
          </li>
        );
      })}
    </ul>
  );
}

export default AppList;
