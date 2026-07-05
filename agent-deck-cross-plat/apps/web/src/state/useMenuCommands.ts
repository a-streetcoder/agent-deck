import { useEffect } from "react";
import { chooseDirectory, nativeBridge } from "@/lib/native";
import { useAppStore } from "./store.ts";
import { addProject, newChat } from "./wsBridge.ts";

/**
 * Wire native application-menu commands (File → New Chat / Add Project…) to the
 * same store actions the sidebar uses. No-op in a plain browser.
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
      }
    });
  }, []);
}
