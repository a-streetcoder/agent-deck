import type { DetailedHTMLProps, HTMLAttributes } from "react";

/**
 * The Electron `<webview>` guest element (Slice L2) — a REAL Chromium guest, not
 * an iframe, so X-Frame-Options / frame-ancestors never block arbitrary sites.
 * Ported from the t3code HostedBrowserWebview.tsx typing (MIT), trimmed to the
 * members the BrowserPanel actually drives. Only instantiates in the Electron
 * shell (the host BrowserWindow sets `webviewTag: true`); the web build never
 * renders it (gated on isElectron()).
 *
 * The tag's DOM methods/events are documented at electronjs.org/docs/latest/api/webview-tag.
 */
export interface ElectronWebviewElement extends HTMLElement {
  src: string;
  partition: string;
  useragent: string;
  getURL(): string;
  getTitle(): string;
  canGoBack(): boolean;
  canGoForward(): boolean;
  goBack(): void;
  goForward(): void;
  reload(): void;
  stop(): void;
  loadURL(url: string): Promise<void>;
  getWebContentsId(): number;
  executeJavaScript(code: string, userGesture?: boolean): Promise<unknown>;
}

/** Attributes accepted on the `<webview>` JSX tag. */
interface WebviewHTMLAttributes extends HTMLAttributes<ElectronWebviewElement> {
  src?: string;
  partition?: string;
  useragent?: string;
  webpreferences?: string;
  preload?: string;
  // `allowpopups` is set imperatively (setAttribute) rather than via JSX — its
  // presence, not a value, is what Electron checks, and the DOM lib already
  // types it as boolean, which clashes with a JSX string attribute.
}

// React 19 exposes the JSX namespace from the "react" module — augment it there
// so `<webview>` is a valid intrinsic element in TSX.
declare module "react" {
  namespace JSX {
    interface IntrinsicElements {
      webview: DetailedHTMLProps<WebviewHTMLAttributes, ElectronWebviewElement>;
    }
  }
}

// So refs / document.querySelector resolve the element to its Electron type.
declare global {
  interface HTMLElementTagNameMap {
    webview: ElectronWebviewElement;
  }
}
