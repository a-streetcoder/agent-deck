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
   * Forward a semantic attention event to the shell (Slice 22a). Fire-and-forget
   * (send, not invoke): the MAIN process owns the focus gate and the OS surface —
   * it decides whether to show a native notification and bump the taskbar/dock
   * badge based on whether the window is currently focused. The renderer only
   * detects the domain transition and forwards it.
   * @param {{ kind: "turn-complete" | "approval-needed", title: string, body: string, sessionId?: string }} payload
   */
  signalAttention: (payload) => ipcRenderer.send("attention", payload),
  /**
   * Subscribe to native-menu commands ("new-chat", "add-project",
   * "open-keybindings"). Returns an unsubscribe function.
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
  /**
   * Subscribe to browser popup requests (Slice L2). A target=_blank / window.open
   * inside a <webview> guest is denied its native child window by the main
   * process, which forwards the http(s) target here; the browser panel opens it
   * as a new internal page-tab. Returns an unsubscribe function.
   * @param {(url: string) => void} handler
   * @returns {() => void}
   */
  onBrowserOpenPage: (handler) => {
    const listener = (_event, url) => handler(url);
    ipcRenderer.on("browser:open-page", listener);
    return () => ipcRenderer.removeListener("browser:open-page", listener);
  },
});
