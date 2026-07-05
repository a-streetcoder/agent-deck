import { useCallback, useEffect, useRef, useState } from "react";
import type { SuggestionItem } from "./SuggestionPanel.tsx";

/**
 * Composer `/` (slash command) and `@` (file) autocomplete. Detects an active
 * trigger token at the caret, fetches matching items for the session, and
 * exposes a keydown handler the textarea calls first (returns true when it
 * consumed the key). Native SlashSuggestionPanel/FileAtSuggestionPanel behavior.
 */

export type SuggestionMode = "slash" | "file" | null;

interface Trigger {
  mode: Exclude<SuggestionMode, null>;
  /** Start index of the trigger char in the text. */
  start: number;
  query: string;
}

/** Find a `/` at line start or `@` preceded by whitespace, up to the caret. */
function detectTrigger(text: string, caret: number): Trigger | null {
  const upto = text.slice(0, caret);
  // Walk back from caret to the trigger char; abort on whitespace.
  for (let i = caret - 1; i >= 0; i -= 1) {
    const ch = upto[i]!;
    if (/\s/.test(ch)) return null;
    if (ch === "@") {
      const before = i === 0 ? "" : upto[i - 1]!;
      if (i === 0 || /\s/.test(before)) {
        return { mode: "file", start: i, query: upto.slice(i + 1) };
      }
      return null;
    }
    if (ch === "/") {
      // Slash commands are only at the very start of the message.
      if (i === 0) return { mode: "slash", start: i, query: upto.slice(i + 1) };
      return null;
    }
  }
  return null;
}

export interface UseSuggestions {
  mode: SuggestionMode;
  items: SuggestionItem[];
  selectedIndex: number;
  setSelectedIndex: (index: number) => void;
  /** Call from the textarea's onChange with the new value + caret. */
  update: (text: string, caret: number) => void;
  /** Returns true if it handled the key (Up/Down/Enter/Tab/Escape while open). */
  handleKeyDown: (event: React.KeyboardEvent) => boolean;
  /** Accept an item; returns the new textarea value + caret. */
  accept: (item: SuggestionItem) => { value: string; caret: number } | null;
  close: () => void;
}

export function useSuggestions(sessionId: string | null): UseSuggestions {
  const [mode, setMode] = useState<SuggestionMode>(null);
  const [items, setItems] = useState<SuggestionItem[]>([]);
  const [selectedIndex, setSelectedIndex] = useState(0);
  const triggerRef = useRef<Trigger | null>(null);
  const textRef = useRef<{ text: string; caret: number }>({ text: "", caret: 0 });
  const reqIdRef = useRef(0);

  const close = useCallback(() => {
    triggerRef.current = null;
    // Invalidate any in-flight fetch so a late response can't reopen the panel
    // (e.g. after a session switch) with stale commands/paths.
    reqIdRef.current += 1;
    setMode(null);
    setItems([]);
    setSelectedIndex(0);
  }, []);

  const fetchItems = useCallback(
    async (trigger: Trigger): Promise<void> => {
      if (!sessionId) return;
      const reqId = ++reqIdRef.current;
      try {
        let next: SuggestionItem[] = [];
        if (trigger.mode === "slash") {
          const response = await fetch(`/sessions/${encodeURIComponent(sessionId)}/commands`);
          if (!response.ok) return;
          const { commands } = (await response.json()) as {
            commands: Array<{ name: string; description?: string; source: string }>;
          };
          const q = trigger.query.toLowerCase();
          next = commands
            .filter((c) => c.name.toLowerCase().includes(q))
            .slice(0, 50)
            .map((c) => ({ id: c.name, label: `/${c.name}`, detail: c.description ?? c.source }));
        } else {
          const response = await fetch(
            `/sessions/${encodeURIComponent(sessionId)}/files?q=${encodeURIComponent(trigger.query)}`,
          );
          if (!response.ok) return;
          const { files } = (await response.json()) as { files: string[] };
          next = files.map((f) => ({ id: f, label: f }));
        }
        if (reqId !== reqIdRef.current) return; // a newer query superseded this
        setItems(next);
        setSelectedIndex(0);
        setMode(next.length > 0 ? trigger.mode : null);
      } catch {
        // Transient; the next keystroke re-queries.
      }
    },
    [sessionId],
  );

  const update = useCallback(
    (text: string, caret: number) => {
      textRef.current = { text, caret };
      const trigger = detectTrigger(text, caret);
      triggerRef.current = trigger;
      if (!trigger) {
        close();
        return;
      }
      void fetchItems(trigger);
    },
    [close, fetchItems],
  );

  const accept = useCallback(
    (item: SuggestionItem): { value: string; caret: number } | null => {
      const trigger = triggerRef.current;
      const { text } = textRef.current;
      if (!trigger) return null;
      const insert = trigger.mode === "slash" ? `/${item.id} ` : `@${item.id} `;
      const before = text.slice(0, trigger.start);
      const after = text.slice(trigger.start + 1 + trigger.query.length);
      const value = before + insert + after;
      close();
      return { value, caret: (before + insert).length };
    },
    [close],
  );

  const handleKeyDown = useCallback(
    (event: React.KeyboardEvent): boolean => {
      if (mode === null || items.length === 0) return false;
      switch (event.key) {
        case "ArrowDown":
          event.preventDefault();
          setSelectedIndex((i) => (i + 1) % items.length);
          return true;
        case "ArrowUp":
          event.preventDefault();
          setSelectedIndex((i) => (i - 1 + items.length) % items.length);
          return true;
        case "Escape":
          event.preventDefault();
          close();
          return true;
        default:
          return false; // Enter/Tab handled by the composer (needs the accept result)
      }
    },
    [mode, items.length, close],
  );

  // Close if the session changes.
  useEffect(() => close(), [sessionId, close]);

  return {
    mode,
    items,
    selectedIndex,
    setSelectedIndex,
    update,
    handleKeyDown,
    accept,
    close,
  };
}
