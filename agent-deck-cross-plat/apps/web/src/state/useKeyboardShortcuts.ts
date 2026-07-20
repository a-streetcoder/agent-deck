import { useEffect } from "react";
import { isTerminalFocused } from "../lib/terminalFocus.ts";
import { newChat, sendAbort, switchToSession } from "./wsBridge.ts";
import { type AppView, useAppStore } from "./store.ts";

/**
 * Global keyboard shortcuts, ported from the native command set
 * (AgentDeckCommands.swift). Dispatched in-app so they work on the web and the
 * Windows/Linux desktop build alike. The primary modifier is Ctrl OR Cmd — Ctrl
 * on Windows/Linux (the port's target platforms), ⌘ on a macOS dev build — and
 * every combo routes to the SAME action the UI already uses. Because all combos
 * require the modifier, they never interfere with plain typing in the composer.
 *
 * Mapped: ⌘1–6 screens, ⌘N new session, ⌘. stop, ⌘] / ⌘[ next/prev session,
 * ⌘S toggle the sessions panel, ⌘` toggle the terminal drawer (the VS Code
 * binding, per the t3code donor). Alt/⌥ and Shift combos are ignored (native
 * reserves those for commands not yet ported — ⌘⌥O add project, ⌘⇧N new agent).
 *
 * While the terminal drawer owns focus (t3code's terminalFocus guard, MIT),
 * only the toggle shortcut fires — every other combo belongs to the shell.
 */
const NAV_KEYS: Record<string, AppView> = {
  "1": "chat",
  "2": "projects",
  "3": "issues",
  "4": "agents",
  "5": "skills",
  "6": "prompts",
};

export function useKeyboardShortcuts(): void {
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent): void => {
      // Primary modifier only; skip Alt/Shift combos (reserved by native).
      if (!(event.ctrlKey || event.metaKey) || event.altKey || event.shiftKey) return;
      // These are discrete actions — ignore OS auto-repeat from a held key so a
      // held ⌘] doesn't flood switch requests.
      if (event.repeat) return;
      const store = useAppStore.getState();

      // Terminal toggle (⌘`/Ctrl+`): the one shortcut that also fires FROM the
      // terminal — xterm's custom key handler declines it so it bubbles here.
      if (event.key === "`") {
        if (store.view !== "chat") return;
        event.preventDefault();
        store.setTerminalOpen(!store.terminalOpen);
        return;
      }
      // Every other combo is the shell's while the terminal owns focus
      // (Ctrl+C interrupt, Ctrl+N history, …) — never hijack those.
      if (isTerminalFocused()) return;

      const navView = NAV_KEYS[event.key];
      if (navView) {
        event.preventDefault();
        store.setView(navView);
        return;
      }

      switch (event.key.toLowerCase()) {
        case "n": // New session
          event.preventDefault();
          store.setView("chat");
          void newChat();
          return;
        case "s": // Toggle the sessions pull-up panel
          event.preventDefault();
          store.setPanelExpanded(!store.panelExpanded);
          return;
      }

      if (event.key === ".") {
        // Stop the running session.
        event.preventDefault();
        sendAbort();
        return;
      }
      if (event.key === "]" || event.key === "[") {
        // Next / previous session in the sidebar list.
        event.preventDefault();
        cycleSession(event.key === "]" ? 1 : -1);
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);
}

// switchToSession() clears the store's `session` synchronously while the resume
// is in flight, so a fast repeat would otherwise recompute from "no selection"
// and jump to the first/last session. Anchor on the last session we targeted so
// successive taps advance adjacently even before the switch resolves.
let lastCycleTargetId: string | null = null;

/** Move selection to the next (+1) or previous (-1) session, wrapping around. */
function cycleSession(direction: 1 | -1): void {
  const { sessions, session, setView } = useAppStore.getState();
  if (sessions.length === 0) return;
  const anchorId = session?.id ?? lastCycleTargetId;
  const currentIndex = anchorId ? sessions.findIndex((s) => s.id === anchorId) : -1;
  const nextIndex =
    currentIndex === -1
      ? direction === 1
        ? 0
        : sessions.length - 1
      : (currentIndex + direction + sessions.length) % sessions.length;
  const target = sessions[nextIndex];
  if (!target) return;
  lastCycleTargetId = target.id;
  if (target.id !== session?.id) {
    setView("chat");
    void switchToSession(target);
  }
}
