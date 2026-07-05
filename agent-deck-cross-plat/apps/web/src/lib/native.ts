/**
 * Access to the Electron preload bridge (window.agentDeck). In a plain browser
 * the bridge is absent, so callers fall back to the type-a-path input.
 */

export interface AgentDeckBridge {
  isElectron?: boolean;
  platform?: string;
  chooseDirectory?(options?: {
    title?: string;
    message?: string;
    buttonLabel?: string;
    multiple?: boolean;
  }): Promise<string[]>;
}

declare global {
  interface Window {
    agentDeck?: AgentDeckBridge;
  }
}

export function nativeBridge(): AgentDeckBridge | undefined {
  return typeof window === "undefined" ? undefined : window.agentDeck;
}

/** True when running inside the Electron shell (native folder picker available). */
export function isElectron(): boolean {
  return nativeBridge()?.isElectron === true;
}

/**
 * True on the macOS desktop build, where the frameless window (hiddenInset)
 * puts the traffic-light buttons over the top-left — content there must clear
 * them.
 */
export function isMacDesktop(): boolean {
  return isElectron() && nativeBridge()?.platform === "darwin";
}

/**
 * Open the native OS folder chooser (the NSOpenPanel equivalent). Resolves to
 * the chosen absolute path(s), or [] if unavailable or the user cancels.
 */
export async function chooseDirectory(
  options?: Parameters<NonNullable<AgentDeckBridge["chooseDirectory"]>>[0],
): Promise<string[]> {
  const bridge = nativeBridge();
  if (!bridge?.chooseDirectory) return [];
  try {
    return (await bridge.chooseDirectory(options)) ?? [];
  } catch {
    // A failed IPC/dialog shouldn't become an unhandled rejection at call sites.
    return [];
  }
}
