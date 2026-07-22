import { useEffect } from "react";
import { commandForChordEvent, resolveKeybindings } from "@agent-deck/contracts";
import { detectPlatform } from "../lib/platform.ts";
import { isTerminalFocused } from "../lib/terminalFocus.ts";
import { commandDefinition, runCommand } from "./commands.ts";
import { useAppStore } from "./store.ts";

/**
 * Global keyboard shortcuts (Slice 14). Every chord resolves through the user's
 * keybinding map (DEFAULT_KEYBINDINGS layered with AppSettings overrides) to a
 * command id, which dispatches through the SAME command catalog the palette
 * uses — there is no parallel hardcoded path, so a rebind applies live the
 * moment the store's `keybindings` change.
 *
 * Defaults preserve the shortcuts the app already had: ⌘1–6 screens, ⌘N new
 * session, ⌘. stop, ⌘] / ⌘[ next/prev session, ⌘S sessions panel, ⌘` terminal
 * (the VS Code binding, per the t3code donor) — plus the new ⌘K palette. The
 * primary modifier is Ctrl on Windows/Linux (the port's targets) and ⌘ on a
 * macOS dev build; `resolveKeybindings`/`commandForChordEvent` handle the swap.
 *
 * While the terminal drawer owns focus (t3code's terminalFocus guard, MIT) only
 * `terminal.toggle` fires (xterm declines that combo so it bubbles here) — every
 * other chord belongs to the shell and passes through untouched.
 */
export function useKeyboardShortcuts(): void {
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent): void => {
      // Discrete actions — ignore OS auto-repeat from a held key so a held ⌘]
      // doesn't flood switch requests.
      if (event.repeat) return;

      const store = useAppStore.getState();
      // While the keybindings editor is open it captures keys for rebind; keep
      // global shortcuts inert so a capture never also fires an action.
      if (store.keybindingsEditorOpen) return;

      const resolved = resolveKeybindings(store.keybindings);
      const command = commandForChordEvent(event, resolved, detectPlatform());
      if (!command) return;

      // With the palette open, only its own toggle acts (to close it); other
      // chords are ignored so navigation can't fire behind the overlay.
      if (store.commandPaletteOpen && command !== "commandPalette.toggle") return;

      const definition = commandDefinition(command);
      if (!definition) return;

      // Shell owns the keyboard while the terminal is focused — only the
      // terminal toggle is allowed through; everything else passes to xterm
      // WITHOUT preventDefault.
      if (!definition.firesInTerminal && isTerminalFocused()) return;

      event.preventDefault();
      runCommand(command);
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);
}
