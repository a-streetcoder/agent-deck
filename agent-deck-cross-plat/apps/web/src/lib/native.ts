/**
 * Access to the Electron preload bridge (window.agentDeck). In a plain browser
 * the bridge is absent, so callers fall back to the type-a-path input.
 */

/** A semantic attention event forwarded to the Electron shell (Slice 22a). */
export interface AttentionPayload {
  kind: "turn-complete" | "approval-needed";
  title: string;
  body: string;
  sessionId?: string;
}

export interface AgentDeckBridge {
  isElectron?: boolean;
  platform?: string;
  chooseDirectory?(options?: {
    title?: string;
    message?: string;
    buttonLabel?: string;
    multiple?: boolean;
  }): Promise<string[]>;
  openAppMenu?(
    name: "file" | "edit" | "view" | "help",
    anchor: { x: number; y: number },
  ): Promise<boolean>;
  /** Subscribe to native-menu commands; returns an unsubscribe function. */
  onMenu?(handler: (action: string) => void): () => void;
  /** Forward a semantic attention event; the main process owns the focus gate. */
  signalAttention?(payload: AttentionPayload): void;
  /**
   * Subscribe to browser popup requests (Slice L2): a target=_blank / window.open
   * inside a `<webview>` guest, denied its native child window and forwarded by
   * the main process for the browser panel to open as an internal page-tab.
   * Returns an unsubscribe function.
   */
  onBrowserOpenPage?(handler: (url: string) => void): () => void;
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
 * Subscribe to browser popup requests (Slice L2). No-op (returns a no-op
 * unsubscribe) in a plain browser or against an older bridge without the method.
 */
export function onBrowserOpenPage(handler: (url: string) => void): () => void {
  const bridge = nativeBridge();
  if (!bridge?.onBrowserOpenPage) return () => {};
  try {
    return bridge.onBrowserOpenPage(handler);
  } catch {
    return () => {};
  }
}

/**
 * True on the macOS desktop build, where the frameless window (hiddenInset)
 * puts the traffic-light buttons over the top-left — content there must clear
 * them.
 */
export function isMacDesktop(): boolean {
  return isElectron() && nativeBridge()?.platform === "darwin";
}

/** True for Electron's custom Windows/Linux title bar. */
export function hasIntegratedDesktopChrome(): boolean {
  return isElectron() && !isMacDesktop();
}

/** Open one of the native menus from the integrated desktop title bar. */
export async function openAppMenu(
  name: "file" | "edit" | "view" | "help",
  anchor: { x: number; y: number },
): Promise<boolean> {
  try {
    return (await nativeBridge()?.openAppMenu?.(name, anchor)) === true;
  } catch {
    return false;
  }
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

/**
 * Forward a semantic attention event (turn complete / approval needed) to the
 * Electron shell (Slice 22a). No-op in a plain browser, or against an older
 * bridge that predates the method. Fire-and-forget: the MAIN process decides
 * whether to actually notify/badge based on window focus, so this never throws
 * at the call site.
 */
export function signalAttention(payload: AttentionPayload): void {
  const bridge = nativeBridge();
  if (!bridge?.signalAttention) return;
  try {
    bridge.signalAttention(payload);
  } catch {
    // A failed IPC must not surface where a domain transition is detected.
  }
}
