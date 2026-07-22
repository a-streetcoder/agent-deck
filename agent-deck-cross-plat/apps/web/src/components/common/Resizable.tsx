import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
  type PointerEvent as ReactPointerEvent,
} from "react";
import { cn } from "@/lib/cn";

/**
 * A reusable horizontal drag-to-resize primitive (Slice L4a), ported from the
 * TerminalDrawer's pointer-capture handle (its vertical resizer) and generalized
 * to a REUSABLE horizontal resizer with a persisted, clamped width.
 *
 * `useResizable` owns one dimension: the current width (seeded from a localStorage
 * key, else `defaultWidth`), the clamp `[min, max]`, and the pointer-capture drag
 * math. {@link ResizeHandle} is the matching draggable strip (an absolutely-
 * positioned hit area over a 1px divider, `cursor-col-resize`).
 *
 * Used in THREE places: the left sidebar edge (App), the right workspace pane
 * edge (TabbedPane), and the Files tree|content split (FilesPanel). Each passes
 * its own storage key + clamps + `edge` (which side the handle sits on, so the
 * drag delta widens in the intuitive direction).
 */

export interface ResizableOptions {
  /** localStorage key the width persists under. */
  storageKey: string;
  /** Seed width when nothing is persisted (clamped into [min, max]). */
  defaultWidth: number;
  min: number;
  max: number;
  /**
   * Which edge of the resized element the handle sits on. `"right"`: dragging
   * right widens (a left sidebar, or the tree column of a left|right split).
   * `"left"`: dragging left widens (a pane whose handle is on its left edge, e.g.
   * the right-hand workspace pane).
   */
  edge: "left" | "right";
}

export interface ResizeHandleProps {
  onPointerDown: (event: ReactPointerEvent<HTMLDivElement>) => void;
  onPointerMove: (event: ReactPointerEvent<HTMLDivElement>) => void;
  onPointerUp: (event: ReactPointerEvent<HTMLDivElement>) => void;
  onPointerCancel: (event: ReactPointerEvent<HTMLDivElement>) => void;
  onKeyDown: (event: ReactKeyboardEvent<HTMLDivElement>) => void;
}

export interface ResizableResult {
  /** The current (clamped) width in px. */
  width: number;
  /** True while a drag is in progress (for a highlight on the handle). */
  isDragging: boolean;
  /** The live clamp bounds (echoed for the handle's aria-valuemin/max). */
  min: number;
  max: number;
  /** Spread onto {@link ResizeHandle} (or any element) to make it draggable. */
  handleProps: ResizeHandleProps;
}

function clampWidth(value: number, min: number, max: number): number {
  // Kept FRACTIONAL (not rounded): a seed derived from a CSS `vw` expression must
  // land on the exact sub-pixel the browser would have used for the same
  // `min(Nvw, Mpx)`, so swapping a fixed CSS width for this seeded width shifts
  // nothing (pixel-sensitive visual baselines stay stable).
  const safe = Number.isFinite(value) ? value : min;
  return Math.min(Math.max(safe, min), max);
}

function readStoredWidth(key: string, fallback: number, min: number, max: number): number {
  try {
    const raw = localStorage.getItem(key);
    if (raw === null) return fallback;
    const parsed = Number.parseFloat(raw);
    return Number.isFinite(parsed) ? clampWidth(parsed, min, max) : fallback;
  } catch {
    // Storage unavailable (private mode / SSR) — fall back to the default.
    return fallback;
  }
}

export function useResizable(options: ResizableOptions): ResizableResult {
  const { storageKey, defaultWidth, min, max, edge } = options;

  const [width, setWidth] = useState(() =>
    readStoredWidth(storageKey, clampWidth(defaultWidth, min, max), min, max),
  );
  const [isDragging, setIsDragging] = useState(false);

  // Live mirror so the pointer-down handler reads the current width without
  // re-binding on every width change (donor's heightRef precedent).
  const widthRef = useRef(width);
  widthRef.current = width;
  const dragRef = useRef<{ pointerId: number; startX: number; startWidth: number } | null>(null);

  const applyWidth = useCallback(
    (next: number) => {
      const clamped = clampWidth(next, min, max);
      setWidth(clamped);
      try {
        localStorage.setItem(storageKey, String(clamped));
      } catch {
        // Storage unavailable — the width still applies for this session.
      }
    },
    [storageKey, min, max],
  );

  const onPointerDown = useCallback((event: ReactPointerEvent<HTMLDivElement>) => {
    if (event.button !== 0) return;
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);
    dragRef.current = {
      pointerId: event.pointerId,
      startX: event.clientX,
      startWidth: widthRef.current,
    };
    setIsDragging(true);
  }, []);

  const onPointerMove = useCallback(
    (event: ReactPointerEvent<HTMLDivElement>) => {
      const state = dragRef.current;
      if (!state || state.pointerId !== event.pointerId) return;
      event.preventDefault();
      const delta = edge === "right" ? event.clientX - state.startX : state.startX - event.clientX;
      applyWidth(state.startWidth + delta);
    },
    [edge, applyWidth],
  );

  const onPointerEnd = useCallback((event: ReactPointerEvent<HTMLDivElement>) => {
    const state = dragRef.current;
    if (!state || state.pointerId !== event.pointerId) return;
    dragRef.current = null;
    setIsDragging(false);
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }
  }, []);

  // Keyboard resize (a11y): ←/→ nudge the boundary; Shift = larger step. The
  // direction matches the drag (moving the handle right widens a "right"-edge
  // element and narrows a "left"-edge one).
  const onKeyDown = useCallback(
    (event: ReactKeyboardEvent<HTMLDivElement>) => {
      const step = event.shiftKey ? 48 : 12;
      let dir = 0;
      if (event.key === "ArrowRight") dir = 1;
      else if (event.key === "ArrowLeft") dir = -1;
      else return;
      event.preventDefault();
      applyWidth(widthRef.current + dir * step * (edge === "right" ? 1 : -1));
    },
    [applyWidth, edge],
  );

  // Re-clamp when the bounds change (a consumer that computes `max` from the
  // viewport passes a smaller max as the window shrinks) so a persisted width
  // can never exceed the current max and overflow the layout. Does not persist —
  // the stored width is preserved so it restores when the window grows again.
  useEffect(() => {
    setWidth((current) => clampWidth(current, min, max));
  }, [min, max]);

  return {
    width,
    isDragging,
    min,
    max,
    handleProps: {
      onPointerDown,
      onPointerMove,
      onPointerUp: onPointerEnd,
      onPointerCancel: onPointerEnd,
      onKeyDown,
    },
  };
}

/**
 * The draggable divider for {@link useResizable}. Deliberately ZERO layout width
 * (`w-0`): the hit strip is an absolutely-positioned overlay centered on the
 * boundary, so adding a handle does NOT shift its neighbors by a pixel — the
 * existing edge borders (the sidebar's `border-r`, the pane's `border-l`) remain
 * the visible rule, and dropping a handle in leaves other layouts (and their
 * visual baselines) untouched. The strip shows a `col-resize` cursor and tints on
 * hover / while dragging; it stays transparent at rest so screenshots are
 * baseline-neutral.
 */
export function ResizeHandle(props: {
  handleProps: ResizeHandleProps;
  isDragging?: boolean;
  className?: string;
  testId?: string;
  ariaLabel?: string;
  /** Current width + bounds for aria-valuenow/min/max (keyboard-resizable). */
  width?: number;
  min?: number;
  max?: number;
}) {
  const { handleProps, isDragging = false, className, testId, ariaLabel, width, min, max } = props;
  const { onKeyDown, ...pointerProps } = handleProps;
  return (
    <div
      role="separator"
      aria-orientation="vertical"
      aria-label={ariaLabel}
      aria-valuenow={width !== undefined ? Math.round(width) : undefined}
      aria-valuemin={min}
      aria-valuemax={max}
      tabIndex={0}
      onKeyDown={onKeyDown}
      data-testid={testId}
      data-dragging={isDragging}
      className={cn(
        "relative z-20 w-0 shrink-0 self-stretch outline-none",
        "focus-visible:ring-2 focus-visible:ring-[var(--color-brand-accent)]",
        className,
      )}
    >
      <div
        className={cn(
          "absolute inset-y-0 left-1/2 w-2 -translate-x-1/2 cursor-col-resize transition-colors",
          isDragging ? "bg-[var(--color-selection-fill)]" : "hover:bg-[var(--color-hover-fill)]",
        )}
        {...pointerProps}
      />
    </div>
  );
}
