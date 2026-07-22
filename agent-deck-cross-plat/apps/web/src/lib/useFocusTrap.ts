import { useEffect, useRef } from "react";

/**
 * Focus trap for a modal container (Slice 19 a11y batch).
 *
 * Keeps keyboard focus inside an `aria-modal` dialog: on mount it moves focus
 * to the first focusable descendant (so a keyboard user isn't stranded behind
 * the overlay), wraps Tab / Shift+Tab around the focusable set, and on unmount
 * restores focus to whatever was focused when the dialog opened. It does NOT
 * own Escape or content shortcuts — the dialog keeps handling those itself, so
 * this composes with an existing keydown effect rather than replacing it.
 *
 * Returns a ref to attach to the dialog container. `active` gates the trap so a
 * conditionally-rendered dialog can pass its open flag (defaults to true for the
 * common "component only mounts while open" case). `initialFocusRef`, when given,
 * receives initial focus instead of the first tabbable descendant — pass it when
 * the DOM-first focusable is not the one you want landed on (e.g. a full-bleed
 * click-to-close backdrop button that precedes the visible close control).
 *
 * AgentEditSheet keeps its own bespoke trap (it couples Escape to a dirty
 * guard + a custom initial-focus target); this hook is for the plainer dialogs.
 */
export function useFocusTrap<T extends HTMLElement>(
  active = true,
  initialFocusRef?: React.RefObject<HTMLElement | null>,
): React.RefObject<T | null> {
  const containerRef = useRef<T | null>(null);

  useEffect(() => {
    if (!active) return;
    const container = containerRef.current;
    if (!container) return;

    const focusables = (): HTMLElement[] =>
      [
        ...container.querySelectorAll<HTMLElement>(
          'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])',
        ),
      ].filter(
        (el) =>
          !el.hasAttribute("disabled") &&
          el.getAttribute("aria-hidden") !== "true" &&
          // `button`/`input`/… match the selector even with tabindex="-1"; keep
          // author-opted-out elements (e.g. a full-bleed click-to-close backdrop)
          // out of the Tab cycle too.
          el.getAttribute("tabindex") !== "-1",
      );

    const previouslyFocused = document.activeElement as HTMLElement | null;
    (initialFocusRef?.current ?? focusables()[0])?.focus();

    const onKeyDown = (event: KeyboardEvent): void => {
      if (event.key !== "Tab") return;
      const items = focusables();
      const first = items[0];
      const last = items[items.length - 1];
      if (!first || !last) return;
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };

    container.addEventListener("keydown", onKeyDown);
    return () => {
      container.removeEventListener("keydown", onKeyDown);
      // Restore focus to the opener (only if it's still in the document).
      if (previouslyFocused && previouslyFocused.isConnected) previouslyFocused.focus();
    };
  }, [active]);

  return containerRef;
}
