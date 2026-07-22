import { useCallback, useEffect, useRef, useState, type FormEvent, type ReactElement } from "react";
import {
  ArrowLeft,
  ArrowRight,
  Globe,
  MousePointerClick,
  Plus,
  RotateCw,
  Square,
  X,
} from "lucide-react";
import { cn } from "@/lib/cn";
import { isElectron, onBrowserOpenPage } from "@/lib/native";
import { useAppStore } from "../../state/store.ts";
import { buildPendingElementContext, newElementContextId } from "../../lib/elementContext.ts";
import { sanitizeHttpUrl } from "../../lib/loopback.ts";
import { PICKER_CODE, PICKER_TEARDOWN_CODE, parsePickResult } from "./picker.ts";
import type { ElectronWebviewElement } from "./electron-webview";

/**
 * The general-purpose desktop browser (Slice L2). Unlike the loopback-only
 * Preview panel (which embeds a dev server in a sandboxed cross-origin
 * `<iframe>`), this loads ANY http(s) site in a REAL Chromium guest — an
 * Electron `<webview>` — so X-Frame-Options / frame-ancestors never block real
 * sites and back/forward/history all work.
 *
 * OPTION B tab model (locked): the browser is a SINGLETON workspace tab kind.
 * Multiple pages are Chrome-style PAGE-TABS *inside* this panel (component-local
 * state), NOT separate workspace tabs. Each page keeps its own live guest across
 * page-tab switches (keep-alive via display:none, mirroring the workspace
 * TabbedPane) so background pages retain their session/history.
 *
 * DESKTOP-ONLY: the `<webview>` tag only instantiates in the Electron shell
 * (webviewTag:true). In the web build isElectron() is false and we render a
 * centered placeholder instead — never an iframe (which real sites block).
 *
 * The toolbar chrome (address form, reload/stop, loading state) is lifted from
 * PreviewPanel's PreviewBrowser and restyled onto our tokens, with the loopback
 * guard dropped (any http(s) is allowed) and back/forward added (now possible
 * with a real guest).
 *
 * L3 (landed): a click-to-select element picker (the "pick" toolbar toggle) is
 * injected into the guest purely via `executeJavaScript` — NO guest preload, NO
 * contextIsolation change (L2's hardening is preserved). The pick resolves to a
 * CSS selector routed through addElementContext (see picker.ts + the pick logic
 * in DesktopBrowser). The ACTIVE page's current URL, always in state (fed by
 * did-navigate) and surfaced as `data-browser-url`, rides onto the context.
 */

/** Cap on live guests. Each page is a full Chromium renderer; N live guests is
 * heavy, so beyond this the "+" / new-window opens are ignored (and logged). */
const MAX_PAGES = 8;

/**
 * A stock desktop Chrome User-Agent forced onto every guest. Electron's default
 * UA carries `Electron/<ver>` and the app name, which Google's embedded-webview
 * detection flags ("This browser or app may not be secure" — sign-in is blocked).
 * Presenting as plain Chrome dodges that. Kept as a fixed recent desktop UA
 * rather than the live platform string so the value is deterministic.
 */
const CHROME_USER_AGENT =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36";

/** The persisted guest partition — one shared session (cookies/storage) for the
 * whole browser, so logins survive across pages and app restarts. */
const BROWSER_PARTITION = "persist:agentdeck-browser";

/** A fresh page's starting document — a blank new-tab state (empty address bar). */
const BLANK_URL = "about:blank";

interface BrowserPage {
  readonly id: string;
  /** The src the guest is created with; set ONCE (React never re-drives it —
   * navigation happens imperatively so the guest is never remounted). */
  readonly initialSrc: string;
  /** Live current URL (from did-navigate); "" while still on about:blank. */
  url: string;
  title: string;
  loading: boolean;
  canGoBack: boolean;
  canGoForward: boolean;
  /** Set from did-fail-load (main frame, non-abort); cleared on the next start. */
  error: string | null;
}

let pageSeq = 0;
function newPage(initialSrc: string = BLANK_URL): BrowserPage {
  pageSeq += 1;
  return {
    id: `browser-page-${pageSeq}`,
    initialSrc,
    url: initialSrc === BLANK_URL ? "" : initialSrc,
    title: "",
    loading: false,
    canGoBack: false,
    canGoForward: false,
    error: null,
  };
}

/**
 * Normalize raw address-bar input to a navigable URL. A scheme-qualified URL is
 * used verbatim; a bare host/`host:port`/`host/path` becomes https:// (http://
 * for localhost); anything else becomes a Google search. Returns null for empty.
 */
export function normalizeAddress(input: string): string | null {
  const raw = input.trim();
  if (!raw) return null;
  if (/^(https?|about|data|file):/i.test(raw)) return raw;
  // A localhost / loopback host keeps http (dev servers rarely have TLS).
  if (/^(localhost|127\.0\.0\.1)(:\d+)?(\/.*)?$/i.test(raw)) return `http://${raw}`;
  // A dotted host (optionally with port/path) and no spaces → assume a URL.
  if (!/\s/.test(raw) && /^[^\s.]+\.[^\s]+$/.test(raw)) return `https://${raw}`;
  // Otherwise treat it as a search query.
  return `https://www.google.com/search?q=${encodeURIComponent(raw)}`;
}

function pageLabel(page: BrowserPage): string {
  if (page.title.trim()) return page.title.trim();
  if (page.url && page.url !== BLANK_URL) {
    try {
      return new URL(page.url).host || page.url;
    } catch {
      return page.url;
    }
  }
  return "New Tab";
}

export function BrowserPanel(): ReactElement {
  if (!isElectron()) return <BrowserPlaceholder />;
  return <DesktopBrowser />;
}

/** The web-build (and non-Electron) body: a real Chromium guest is unavailable,
 * so we show a placeholder rather than an iframe (real sites block framing). */
function BrowserPlaceholder(): ReactElement {
  return (
    <div
      className="flex min-h-0 flex-1 flex-col items-center justify-center gap-3 bg-surface p-8 text-center"
      data-testid="browser-placeholder"
    >
      <Globe className="h-8 w-8 text-text-muted" aria-hidden />
      <p className="max-w-xs text-sm text-text-secondary">
        The browser is available in the desktop app.
      </p>
    </div>
  );
}

function DesktopBrowser(): ReactElement {
  const [pages, setPages] = useState<BrowserPage[]>(() => [newPage()]);
  const [activePageId, setActivePageId] = useState<string>(() => pages[0]!.id);
  // Address-bar draft + focus, reseeded from the active page's URL (donor idiom).
  const [draft, setDraft] = useState("");
  const [addressFocused, setAddressFocused] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);
  // pageId → live guest element, populated by each page's ref callback.
  const webviewRefs = useRef<Map<string, ElectronWebviewElement>>(new Map());

  const activePage = pages.find((p) => p.id === activePageId) ?? pages[0]!;

  const patchPage = useCallback((id: string, patch: Partial<BrowserPage>) => {
    setPages((prev) => prev.map((p) => (p.id === id ? { ...p, ...patch } : p)));
  }, []);

  const setWebviewEl = useCallback((id: string, el: ElectronWebviewElement | null) => {
    if (el) webviewRefs.current.set(id, el);
    else webviewRefs.current.delete(id);
  }, []);

  // A render-synced mirror of `pages` so open/close can read the live array and
  // keep their state updaters PURE (no newPage()/setActivePageId side effects
  // inside a setPages updater, which React StrictMode double-invokes).
  const pagesRef = useRef<BrowserPage[]>(pages);
  pagesRef.current = pages;

  const openPage = useCallback((initialSrc?: string) => {
    if (pagesRef.current.length >= MAX_PAGES) {
      console.warn(`[browser] page cap (${MAX_PAGES}) reached — ignoring new tab`);
      return;
    }
    const page = newPage(initialSrc); // created ONCE, outside the updater
    setPages((prev) => [...prev, page]);
    setActivePageId(page.id);
  }, []);

  const closePage = useCallback((id: string) => {
    const prev = pagesRef.current;
    webviewRefs.current.delete(id);
    if (prev.length <= 1) {
      // Never leave zero pages: reset the sole page to a fresh blank tab.
      const page = newPage();
      setPages([page]);
      setActivePageId(page.id);
      return;
    }
    const index = prev.findIndex((p) => p.id === id);
    const next = prev.filter((p) => p.id !== id);
    setPages(next);
    setActivePageId((current) =>
      current === id ? next[Math.min(Math.max(index, 0), next.length - 1)]!.id : current,
    );
  }, []);

  // Reseed the address draft whenever the active page changes or navigates,
  // unless the user is mid-edit (focused).
  useEffect(() => {
    if (!addressFocused) setDraft(activePage.url);
  }, [activePage.url, activePage.id, addressFocused]);

  // Popups (target=_blank / window.open) do NOT surface as a <webview> DOM event
  // in modern Electron (the `new-window` DOM event was removed). Instead the MAIN
  // process denies the native popup in the guest's window-open handler and
  // forwards the target URL here over IPC; we open it as a new internal page-tab.
  useEffect(() => onBrowserOpenPage((url) => openPage(url)), [openPage]);

  const navigate = useCallback(
    (event?: FormEvent) => {
      event?.preventDefault();
      const target = normalizeAddress(draft);
      const el = webviewRefs.current.get(activePageId);
      if (!target || !el) return;
      inputRef.current?.blur();
      try {
        // Setting .src navigates the existing guest in place (no remount).
        el.src = target;
      } catch {
        // A guest not yet attached — harmless; the next attempt will land.
      }
    },
    [draft, activePageId],
  );

  const withActive = useCallback(
    (run: (el: ElectronWebviewElement) => void) => {
      const el = webviewRefs.current.get(activePageId);
      if (!el) return;
      try {
        run(el);
      } catch {
        // Guest not ready / method unavailable — ignore.
      }
    },
    [activePageId],
  );

  // ── L3: click-to-select element picker ────────────────────────────────────
  // The user toggles pick mode, hovers the guest (elements highlight), and
  // clicks one; that element's CSS selector + page URL become a pending element
  // context on the CURRENT session's composer (existing lib/elementContext +
  // store path — the Composer already drains + serializes it). SINGLE-SHOT: one
  // click captures and deactivates; toggling off, Escape, page-tab switch, or
  // unmount all cancel + tear the guest picker down (no leaked listeners). The
  // injection is executeJavaScript-ONLY — no guest preload, no contextIsolation
  // change (L2's hardening is preserved).
  const sessionId = useAppStore((state) => state.session?.id ?? null);
  const addElementContext = useAppStore((state) => state.addElementContext);
  const pushToast = useAppStore((state) => state.pushToast);

  const [picking, setPicking] = useState(false);
  // The page id a picker is currently installed in (for targeted teardown).
  const pickingPageIdRef = useRef<string | null>(null);
  // Monotonic token; a bump invalidates any in-flight pick resolution so a late
  // guest click after cancel/page-switch is ignored.
  const pickTokenRef = useRef(0);

  const teardownPick = useCallback(() => {
    const id = pickingPageIdRef.current;
    pickingPageIdRef.current = null;
    if (!id) return;
    const el = webviewRefs.current.get(id);
    if (!el) return;
    try {
      void el.executeJavaScript(PICKER_TEARDOWN_CODE, false).catch(() => {});
    } catch {
      // Guest gone / method unavailable — nothing to tear down.
    }
  }, []);

  const deactivatePick = useCallback(() => {
    pickTokenRef.current += 1; // invalidate any in-flight resolve
    teardownPick();
    setPicking(false);
  }, [teardownPick]);

  const startPick = useCallback(() => {
    const pageId = activePageId;
    const el = webviewRefs.current.get(pageId);
    if (!el) return;
    const token = (pickTokenRef.current += 1);
    pickingPageIdRef.current = pageId;
    setPicking(true);
    let promise: Promise<unknown>;
    try {
      promise = el.executeJavaScript(PICKER_CODE, true);
    } catch {
      pickingPageIdRef.current = null;
      setPicking(false);
      return;
    }
    void promise
      .then((raw) => {
        // Superseded (toggled off / page switched / re-picked) — ignore.
        if (pickTokenRef.current !== token) return;
        pickingPageIdRef.current = null;
        setPicking(false);
        const result = parsePickResult(raw);
        if (!result) return; // Escape / non-element / cancel
        if (sessionId === null) return; // no session → nothing to attach to
        let pageUrl = "";
        try {
          pageUrl = el.getURL();
        } catch {
          pageUrl = "";
        }
        const context = buildPendingElementContext({
          id: newElementContextId(),
          pageUrl,
          selector: result.selector,
          // The real tag from the picker (an #id selector can't derive it), and
          // the element's visible text as the note so the agent has both.
          tagName: result.tagName,
          note: result.text,
          // The general browser captures ANY site's URL (not loopback-only).
          sanitizeUrl: sanitizeHttpUrl,
        });
        if (!context) return;
        addElementContext(sessionId, context);
        pushToast({ kind: "success", message: `Captured <${result.tagName}> for context` });
      })
      .catch(() => {
        // Guest navigated away mid-pick (executeJavaScript rejects) — no-op.
        if (pickTokenRef.current !== token) return;
        pickingPageIdRef.current = null;
        setPicking(false);
      });
  }, [activePageId, sessionId, addElementContext, pushToast]);

  const togglePick = useCallback(() => {
    if (picking) deactivatePick();
    else startPick();
  }, [picking, deactivatePick, startPick]);

  // Cancel an in-flight pick if the user switches page-tabs (the picker lives in
  // the previously-active guest; don't leak its listeners there).
  useEffect(() => {
    if (picking && pickingPageIdRef.current && pickingPageIdRef.current !== activePageId) {
      deactivatePick();
    }
  }, [activePageId, picking, deactivatePick]);

  // Tear the guest picker down on unmount (closing the browser tab).
  useEffect(() => () => deactivatePick(), [deactivatePick]);

  // Pick is pointless on a blank tab with no navigable URL.
  const canPick = Boolean(activePage.url);

  return (
    <div
      className="flex min-h-0 flex-1 flex-col"
      data-testid="browser-panel"
      data-browser-url={activePage.url}
    >
      {/* The internal page-tab strip (Option B multi-page), scoped inside the
          browser and styled like the workspace TabStrip. */}
      <div
        className="flex items-center gap-1 border-b border-border-subtle px-1.5 py-1"
        data-testid="browser-tab-strip"
      >
        <div className="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto" role="tablist">
          {pages.map((page) => {
            const active = page.id === activePageId;
            return (
              <div
                key={page.id}
                className={cn(
                  "group flex h-7 min-w-0 max-w-40 shrink-0 items-center gap-1.5 rounded-md pl-2 pr-1 text-xs",
                  active
                    ? "bg-[var(--color-selection-fill)] text-text-primary"
                    : "text-text-muted hover:bg-[var(--color-hover-fill)] hover:text-text-primary",
                )}
              >
                <button
                  type="button"
                  role="tab"
                  aria-selected={active}
                  className="flex min-w-0 flex-1 items-center gap-1.5"
                  data-testid="browser-page-tab"
                  data-active={active}
                  title={pageLabel(page)}
                  onClick={() => setActivePageId(page.id)}
                >
                  {page.loading ? (
                    <RotateCw className="h-3 w-3 shrink-0 animate-spin" aria-hidden />
                  ) : (
                    <Globe className="h-3.5 w-3.5 shrink-0" aria-hidden />
                  )}
                  <span className="truncate">{pageLabel(page)}</span>
                </button>
                <button
                  type="button"
                  className={cn(
                    "flex size-4 shrink-0 items-center justify-center rounded hover:bg-[var(--color-hover-fill)] hover:text-text-primary",
                    active ? "opacity-100" : "opacity-0 group-hover:opacity-100",
                  )}
                  data-testid="browser-page-close"
                  aria-label={`Close ${pageLabel(page)}`}
                  title={`Close ${pageLabel(page)}`}
                  onClick={(event) => {
                    event.stopPropagation();
                    closePage(page.id);
                  }}
                >
                  <X className="h-3 w-3" aria-hidden />
                </button>
              </div>
            );
          })}
        </div>
        <button
          type="button"
          className="flex size-7 shrink-0 items-center justify-center rounded-md text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary disabled:cursor-not-allowed disabled:opacity-40"
          data-testid="browser-new-page"
          aria-label="New page"
          title={pages.length >= MAX_PAGES ? `At most ${MAX_PAGES} pages` : "New page"}
          disabled={pages.length >= MAX_PAGES}
          onClick={() => openPage()}
        >
          <Plus className="h-4 w-4" aria-hidden />
        </button>
      </div>

      {/* The address toolbar (shared, acts on the active page). */}
      <form
        onSubmit={navigate}
        className="flex items-center gap-1 border-b border-border-subtle px-2 py-1.5"
      >
        <button
          type="button"
          className="shrink-0 rounded p-1 text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary disabled:cursor-not-allowed disabled:opacity-30"
          title="Back"
          aria-label="Back"
          data-testid="browser-back"
          disabled={!activePage.canGoBack}
          onClick={() => withActive((el) => el.goBack())}
        >
          <ArrowLeft className="h-3.5 w-3.5" />
        </button>
        <button
          type="button"
          className="shrink-0 rounded p-1 text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary disabled:cursor-not-allowed disabled:opacity-30"
          title="Forward"
          aria-label="Forward"
          data-testid="browser-forward"
          disabled={!activePage.canGoForward}
          onClick={() => withActive((el) => el.goForward())}
        >
          <ArrowRight className="h-3.5 w-3.5" />
        </button>
        <button
          type="button"
          className="shrink-0 rounded p-1 text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
          title={activePage.loading ? "Stop" : "Reload"}
          aria-label={activePage.loading ? "Stop" : "Reload"}
          data-testid="browser-reload"
          onClick={() => withActive((el) => (activePage.loading ? el.stop() : el.reload()))}
        >
          {activePage.loading ? (
            <Square className="h-3.5 w-3.5" />
          ) : (
            <RotateCw className="h-3.5 w-3.5" />
          )}
        </button>
        <button
          type="button"
          className={cn(
            "shrink-0 rounded p-1 transition-colors disabled:cursor-not-allowed disabled:opacity-30",
            picking
              ? "bg-accent text-[var(--color-accent-foreground)]"
              : "text-text-muted hover:bg-[var(--color-hover-fill)] hover:text-text-primary",
          )}
          title="Pick an element for context"
          aria-label="Pick an element for context"
          aria-pressed={picking}
          data-testid="browser-pick"
          data-active={picking}
          disabled={!canPick}
          onClick={togglePick}
        >
          <MousePointerClick className="h-3.5 w-3.5" />
        </button>
        <input
          ref={inputRef}
          className="min-w-0 flex-1 rounded-md border border-border-subtle bg-surface px-2 py-1 font-mono text-[11px] text-text-primary focus:border-accent focus:outline-none"
          data-testid="browser-url-input"
          value={draft}
          spellCheck={false}
          onChange={(event) => setDraft(event.target.value)}
          onFocus={() => setAddressFocused(true)}
          onBlur={() => {
            setAddressFocused(false);
            setDraft(activePage.url);
          }}
          onKeyDown={(event) => {
            if (event.key === "Escape") {
              event.preventDefault();
              setDraft(activePage.url);
              inputRef.current?.blur();
            }
          }}
          aria-label="Address"
          placeholder="Search or enter address"
        />
        <span
          className="hidden min-w-0 max-w-[16ch] shrink truncate pl-1 text-[11px] text-text-muted sm:block"
          data-testid="browser-page-title"
          title={activePage.title}
        >
          {activePage.title}
        </span>
      </form>

      {/* One live guest per page; inactive pages are hidden (display:none) but
          NOT unmounted, so their session/history survive page-tab switches. */}
      <div className="relative min-h-0 flex-1 bg-white">
        {pages.map((page) => (
          <BrowserPageView
            key={page.id}
            page={page}
            active={page.id === activePageId}
            registerEl={setWebviewEl}
            onNav={patchPage}
          />
        ))}
      </div>
    </div>
  );
}

/**
 * One page's live `<webview>` guest. Renders the element (created ONCE with a
 * static `src`) and wires the Electron webview events to the parent's page
 * state. Hidden with display:none when inactive (keep-alive) — never unmounted
 * except when its page-tab is closed.
 */
function BrowserPageView(props: {
  page: BrowserPage;
  active: boolean;
  registerEl: (id: string, el: ElectronWebviewElement | null) => void;
  onNav: (id: string, patch: Partial<BrowserPage>) => void;
}): ReactElement {
  const { page, active, registerEl, onNav } = props;
  const elRef = useRef<ElectronWebviewElement | null>(null);
  const id = page.id;

  const setRef = useCallback(
    (node: ElectronWebviewElement | null) => {
      elRef.current = node;
      // Electron needs `allowpopups` as an attribute for window.open/target=_blank
      // to surface as a "new-window" event rather than being silently dropped.
      if (node && !node.hasAttribute("allowpopups")) node.setAttribute("allowpopups", "true");
      registerEl(id, node);
    },
    [id, registerEl],
  );

  useEffect(() => {
    const el = elRef.current;
    if (!el) return;

    const syncNavFlags = () => {
      try {
        onNav(id, { canGoBack: el.canGoBack(), canGoForward: el.canGoForward() });
      } catch {
        // Methods unavailable before attach — the next event retries.
      }
    };
    const onStart = () => onNav(id, { loading: true, error: null });
    const onStop = () => {
      onNav(id, { loading: false });
      syncNavFlags();
    };
    const onDidNavigate = (event: Event) => {
      const raw = (event as unknown as { url?: string }).url ?? "";
      // A blank tab really navigates to about:blank; keep the address bar EMPTY
      // for it (real browsers don't print "about:blank" in a new tab).
      onNav(id, { url: raw === BLANK_URL ? "" : raw, error: null });
      syncNavFlags();
    };
    const onInPage = (event: Event) => {
      const e = event as unknown as { url?: string; isMainFrame?: boolean };
      if (e.isMainFrame === false) return;
      const raw = e.url ?? "";
      onNav(id, { url: raw === BLANK_URL ? "" : raw });
      syncNavFlags();
    };
    const onTitle = (event: Event) => {
      const title = (event as unknown as { title?: string }).title ?? "";
      onNav(id, { title });
    };
    const onFail = (event: Event) => {
      const e = event as unknown as {
        errorCode?: number;
        errorDescription?: string;
        isMainFrame?: boolean;
      };
      // -3 (ERR_ABORTED) fires on ordinary redirects/user-cancels — not a failure.
      if (e.isMainFrame === false || e.errorCode === -3) return;
      onNav(id, {
        loading: false,
        error: e.errorDescription || `Load failed (${e.errorCode ?? "?"})`,
      });
    };
    el.addEventListener("did-start-loading", onStart);
    el.addEventListener("did-stop-loading", onStop);
    el.addEventListener("did-navigate", onDidNavigate);
    el.addEventListener("did-navigate-in-page", onInPage);
    el.addEventListener("page-title-updated", onTitle);
    el.addEventListener("did-fail-load", onFail);
    return () => {
      el.removeEventListener("did-start-loading", onStart);
      el.removeEventListener("did-stop-loading", onStop);
      el.removeEventListener("did-navigate", onDidNavigate);
      el.removeEventListener("did-navigate-in-page", onInPage);
      el.removeEventListener("page-title-updated", onTitle);
      el.removeEventListener("did-fail-load", onFail);
    };
  }, [id, onNav]);

  return (
    <div className={cn("absolute inset-0", active ? "block" : "hidden")}>
      <webview
        ref={setRef}
        src={page.initialSrc}
        partition={BROWSER_PARTITION}
        useragent={CHROME_USER_AGENT}
        data-testid="browser-webview"
        data-page-id={page.id}
        className="h-full w-full border-0"
        style={{ display: "flex", width: "100%", height: "100%" }}
      />
      {page.error ? (
        <div
          className="pointer-events-none absolute inset-x-0 top-0 bg-[rgba(229,116,108,0.15)] px-3 py-2 text-center text-xs text-[var(--color-role-error)]"
          data-testid="browser-error"
        >
          {page.error}
        </div>
      ) : null}
    </div>
  );
}
