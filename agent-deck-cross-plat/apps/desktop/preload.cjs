// Preload bridge (CommonJS so it loads cleanly under the sandbox).
//
// Exposes a tiny, allow-listed surface on window.agentDeck. The web UI checks
// `window.agentDeck?.isElectron` to prefer the native folder picker over the
// type-a-path fallback it uses in a plain browser.
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("agentDeck", {
  isElectron: true,
  platform: process.platform,
  /**
   * Open the native folder chooser. Resolves to the selected absolute path(s),
   * or [] if the user cancels.
   * @param {{ title?: string, message?: string, buttonLabel?: string, multiple?: boolean }} [options]
   * @returns {Promise<string[]>}
   */
  chooseDirectory: (options) => ipcRenderer.invoke("dialog:openDirectory", options),
  /** Open a native menu at a renderer-provided titlebar anchor. */
  openAppMenu: (name, anchor) => ipcRenderer.invoke("app-menu:open", name, anchor),
  /**
   * Subscribe to native-menu commands ("new-chat", "add-project"). Returns an
   * unsubscribe function.
   * @param {(action: string) => void} handler
   * @returns {() => void}
   */
  onMenu: (handler) => {
    // The preload context can survive a renderer reload. Clear any listener
    // owned by the previous React tree so one native menu click stays one
    // action after reloads (including development hot reloads).
    ipcRenderer.removeAllListeners("menu");
    const listener = (_event, action) => handler(action);
    ipcRenderer.on("menu", listener);
    return () => ipcRenderer.removeListener("menu", listener);
  },
});
