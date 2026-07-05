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
});
