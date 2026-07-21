import { useEffect } from "react";
import { chooseDirectory, nativeBridge } from "@/lib/native";
import { useAppStore } from "./store.ts";
import { addProject, newChat } from "./wsBridge.ts";

/**
 * Wire native application-menu commands (File → New Chat / Add Project… / Edit
 * Keybindings…) to the same store actions the sidebar/palette use. No-op in a
 * plain browser.
 *
 * `open-keybindings` is the deliberate non-rebindable recovery path into the
 * keybindings editor: the command palette is its only other entry point and the
 * palette's own open-chord is user-rebindable, so this native-menu item is what
 * lets a user reopen the editor and reset even if they lose that binding.
 */
export function useMenuCommands(): void {
  useEffect(() => {
    const bridge = nativeBridge();
    if (!bridge?.onMenu) return;
    return bridge.onMenu((action) => {
      if (action === "new-chat") {
        useAppStore.getState().setView("chat");
        void newChat();
      } else if (action === "add-project") {
        void chooseDirectory({
          title: "Add Project",
          message: "Choose a repo or project root to add",
        }).then(([picked]) => {
          if (picked) void addProject(picked);
        });
      } else if (action === "open-keybindings") {
        const store = useAppStore.getState();
        store.setCommandPaletteOpen(false);
        store.setKeybindingsEditorOpen(true);
      }
    });
  }, []);
}
