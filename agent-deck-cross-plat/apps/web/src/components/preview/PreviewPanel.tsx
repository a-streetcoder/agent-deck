import { useCallback, useEffect, useRef, useState, type FormEvent, type RefObject } from "react";
import { ArrowLeft, ExternalLink, Play, RefreshCw, RotateCw, Square, X } from "lucide-react";
import type { DiscoveredServer, ProjectScript } from "@agent-deck/contracts";
import { cn } from "@/lib/cn";
import { useAppStore } from "../../state/store.ts";
import {
  attachSessionRun,
  getSessionRunId,
  listSessionScripts,
  startSessionScript,
  stopSessionScript,
  subscribeScriptPush,
} from "../../state/wsBridge.ts";

/**
 * The dev-server preview panel (Slice 15b): a right-hand aside on the chat
 * surface — a sibling to the diff / files panels (same shell idiom) — that runs
 * the CURRENT session's `package.json` scripts and embeds the loopback
 * dev-server URL they start listening on.
 *
 * Pattern-ported from t3code's preview surface (MIT): ProjectScriptsControl (the
 * run control), PreviewChromeRow (the URL bar), PreviewView / PreviewEmptyState
 * (the embed + discovered-server states), condensed to our smaller op surface
 * and re-expressed over our RPC transport (wsBridge script ops) and tokens. Two
 * deliberate design deltas from the donor:
 *   - The donor runs setup scripts and scans ALL listening sockets; we run one
 *     DECLARED script as a managed child (server-allocated run id) and detect the
 *     port from THAT run's own stdout (services/scriptRunner.ts), so a discovered
 *     server is always this run's.
 *   - The embed is a plain `<iframe>` pointed at the loopback URL — it works in a
 *     browser AND inside the Electron shell (no webview/BrowserView needed; the
 *     desktop bridge exposes none). The parent can never read a cross-origin
 *     frame's content or history, so back/forward are dropped: the chrome is a
 *     URL bar + reload + open-in-system-browser (Slice 16 adds automation).
 *
 * Lifecycle mirrors the terminal drawer: the panel renders null while closed, so
 * a session that never opens it never spawns a dev server. Opening lists the
 * scripts and, if this connection still has a live run for the session,
 * reattaches to it (scrollback + the current server replay). The run itself is
 * owned by the RPC connection server-side: a disconnect / session exit / the
 * Stop button all tree-kill the child (no orphan dev servers).
 */

/** Cap the live-output buffer (the server already caps scrollback; this bounds
 * the DOM for a chatty dev server between refreshes). */
const MAX_LOG_CHARS = 200_000;
/** How long the iframe may spin before we surface a "still starting?" hint. */
const IFRAME_LOAD_HINT_MS = 8_000;

/** Prefer a `dev`/`start` script as the default selection, else the first. */
function preferredScript(scripts: readonly ProjectScript[]): string | null {
  if (scripts.length === 0) return null;
  const preferred =
    scripts.find((s) => s.name === "dev") ?? scripts.find((s) => s.name === "start");
  return (preferred ?? scripts[0]!).name;
}

function appendLog(previous: string, chunk: string): string {
  const next = previous + chunk;
  return next.length > MAX_LOG_CHARS ? next.slice(next.length - MAX_LOG_CHARS) : next;
}

/**
 * Loopback hosts only — localhost, the 127.0.0.0/8 block, and IPv6 ::1. The
 * preview embeds the user's OWN locally-run dev server; embedding an arbitrary
 * external origin is the invariant the whole feature rests on (a sandboxed
 * iframe with `allow-scripts allow-same-origin` pointed at attacker content
 * could still be a phishing/clickjacking surface inside the app window).
 */
function isLoopbackHost(hostname: string): boolean {
  const h = hostname.toLowerCase().replace(/^\[|\]$/g, "");
  return h === "localhost" || h === "::1" || /^127(?:\.\d{1,3}){3}$/.test(h);
}

/**
 * Parse+validate a URL for embedding: http(s) on a loopback host, or null. This
 * is enforced at BOTH input points (the URL bar below) AND the iframe-src
 * boundary, so no matter how a URL reaches previewUrl (typed, or a discovered
 * server frame), a non-loopback origin can never become an iframe src.
 */
function toLoopbackEmbedUrl(raw: string): string | null {
  const trimmed = raw.trim();
  if (trimmed.length === 0) return null;
  const candidate = /^https?:\/\//i.test(trimmed) ? trimmed : `http://${trimmed}`;
  try {
    const url = new URL(candidate);
    if (url.protocol !== "http:" && url.protocol !== "https:") return null;
    if (!isLoopbackHost(url.hostname)) return null;
    // Return the validated candidate VERBATIM (not url.toString(), which would
    // append a trailing slash / re-normalize) so the URL bar and the iframe src
    // stay byte-identical to the discovered/typed URL.
    return candidate;
  } catch {
    return null;
  }
}

export function PreviewPanel() {
  const open = useAppStore((state) => state.previewPanelOpen);
  const setOpen = useAppStore((state) => state.setPreviewPanelOpen);
  const sessionId = useAppStore((state) => state.session?.id ?? null);
  const connection = useAppStore((state) => state.connection);
  const connected = connection === "open";

  const [scripts, setScripts] = useState<readonly ProjectScript[]>([]);
  const [scriptsLoading, setScriptsLoading] = useState(false);
  const [selected, setSelected] = useState<string | null>(null);
  const [runId, setRunId] = useState<string | null>(null);
  const [running, setRunning] = useState(false);
  const [log, setLog] = useState("");
  const [server, setServer] = useState<DiscoveredServer | null>(null);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const [startError, setStartError] = useState<string | null>(null);

  // The push listener filters by the ACTIVE run id, which is set async (start /
  // reattach) — a ref keeps the stable subscription current without re-subscribing.
  const runIdRef = useRef<string | null>(null);
  runIdRef.current = runId;
  const logEndRef = useRef<HTMLDivElement>(null);

  const loadScripts = useCallback(async () => {
    setScriptsLoading(true);
    try {
      const list = await listSessionScripts();
      setScripts(list);
      setSelected((current) => current ?? preferredScript(list));
    } catch {
      // Offline / torn-down session: leave the (reset) list — reopening refetches.
    } finally {
      setScriptsLoading(false);
    }
  }, []);

  // On (open, session, connection) episode: reset, list scripts, and reattach to
  // any run this connection still owns for the session (scrollback + server
  // replay). Reconnects re-run it — a drop killed the run server-side.
  useEffect(() => {
    if (!open || !sessionId || !connected) return;
    let cancelled = false;

    setScripts([]);
    setSelected(null);
    setRunId(null);
    setRunning(false);
    setLog("");
    setServer(null);
    setPreviewUrl(null);
    setStartError(null);

    void loadScripts();

    const existingRun = getSessionRunId();
    if (existingRun !== null) {
      void attachSessionRun(existingRun)
        .then((result) => {
          if (cancelled) return;
          setRunId(result.runId);
          setRunning(result.running);
          setLog(result.scrollback);
          setServer(result.server);
          // Re-embed straight away if the dev server is already up.
          if (result.server) setPreviewUrl((current) => current ?? result.server!.url);
        })
        .catch(() => {
          // The run vanished (exited + swept): fall back to the scripts list.
        });
    }

    const unsubscribe = subscribeScriptPush((message) => {
      if (message.runId !== runIdRef.current) return;
      if (message.type === "script_output") {
        setLog((previous) => appendLog(previous, message.data));
        return;
      }
      if (message.type === "script_server") {
        setServer(message.server);
        setPreviewUrl((current) => current ?? message.server.url);
        return;
      }
      // script_exit
      setRunning(false);
      setLog((previous) =>
        appendLog(previous, `\n[dev server exited (code ${message.exitCode ?? "?"})]\n`),
      );
    });

    return () => {
      cancelled = true;
      unsubscribe();
    };
  }, [open, sessionId, connected, loadScripts]);

  // Keep the log scrolled to the tail as output streams in.
  useEffect(() => {
    logEndRef.current?.scrollIntoView({ block: "end" });
  }, [log]);

  const onRun = useCallback(async () => {
    if (selected === null) return;
    setStartError(null);
    setLog("");
    setServer(null);
    setPreviewUrl(null);
    try {
      const result = await startSessionScript(selected);
      setRunId(result.runId);
      setRunning(result.running);
      if (result.scrollback.length > 0) setLog(result.scrollback);
      if (result.server) {
        setServer(result.server);
        setPreviewUrl(result.server.url);
      }
    } catch (error) {
      setStartError(error instanceof Error ? error.message : String(error));
    }
  }, [selected]);

  const onStop = useCallback(() => {
    if (sessionId === null) return;
    stopSessionScript(sessionId);
    setRunning(false);
  }, [sessionId]);

  if (!open || sessionId === null) return null;

  const inPreview = previewUrl !== null;

  return (
    <aside
      className="flex shrink-0 flex-col overflow-hidden border-l border-border-subtle bg-surface-elevated"
      style={{ width: inPreview ? "min(46vw, 640px)" : "320px" }}
      data-testid="preview-panel"
    >
      {inPreview ? (
        <PreviewBrowser
          url={previewUrl}
          onNavigate={(next) => setPreviewUrl(next)}
          onBack={() => setPreviewUrl(null)}
          onClose={() => setOpen(false)}
        />
      ) : (
        <ScriptsRunner
          scripts={scripts}
          scriptsLoading={scriptsLoading}
          selected={selected}
          onSelect={setSelected}
          running={running}
          log={log}
          server={server}
          startError={startError}
          logEndRef={logEndRef}
          onRun={() => void onRun()}
          onStop={onStop}
          onRefresh={() => void loadScripts()}
          onClose={() => setOpen(false)}
          onOpenServer={(url) => setPreviewUrl(url)}
        />
      )}
    </aside>
  );
}

// ---------------------------------------------------------------------------
// The scripts runner (idle state): the run control + streamed output + the
// discovered-server card (the donor's ProjectScriptsControl + PreviewEmptyState).
// ---------------------------------------------------------------------------

function ScriptsRunner(props: {
  scripts: readonly ProjectScript[];
  scriptsLoading: boolean;
  selected: string | null;
  onSelect: (name: string) => void;
  running: boolean;
  log: string;
  server: DiscoveredServer | null;
  startError: string | null;
  logEndRef: RefObject<HTMLDivElement | null>;
  onRun: () => void;
  onStop: () => void;
  onRefresh: () => void;
  onClose: () => void;
  onOpenServer: (url: string) => void;
}) {
  const {
    scripts,
    scriptsLoading,
    selected,
    onSelect,
    running,
    log,
    server,
    startError,
    logEndRef,
    onRun,
    onStop,
    onRefresh,
    onClose,
    onOpenServer,
  } = props;
  const hasScripts = scripts.length > 0;

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      {/* Subheader row (matches the diff / files panels). */}
      <div className="flex items-center justify-between gap-2 border-b border-border-subtle px-3 py-2">
        <span
          className="text-xs font-semibold uppercase tracking-wide text-text-muted"
          style={{ fontStretch: "expanded" }}
        >
          Preview
        </span>
        <div className="flex shrink-0 items-center gap-1">
          <button
            type="button"
            className="rounded p-1 text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
            title="Refresh scripts"
            aria-label="Refresh scripts"
            data-testid="preview-refresh"
            onClick={onRefresh}
          >
            <RefreshCw className={cn("h-3.5 w-3.5", scriptsLoading && "animate-spin")} />
          </button>
          <button
            type="button"
            className="rounded p-1 text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
            title="Close preview panel"
            aria-label="Close preview panel"
            data-testid="preview-close"
            onClick={onClose}
          >
            <X className="h-3.5 w-3.5" />
          </button>
        </div>
      </div>

      {/* Run control: pick a declared script, start / stop it. */}
      <div className="flex items-center gap-2 border-b border-border-subtle px-3 py-2">
        <select
          className="min-w-0 flex-1 truncate rounded-md border border-border-subtle bg-surface px-2 py-1 font-mono text-xs text-text-primary disabled:opacity-50"
          data-testid="preview-script-select"
          value={selected ?? ""}
          disabled={!hasScripts || running}
          onChange={(event) => onSelect(event.target.value)}
        >
          {hasScripts ? (
            scripts.map((script) => (
              <option key={script.name} value={script.name}>
                {script.name}
              </option>
            ))
          ) : (
            <option value="">No scripts</option>
          )}
        </select>
        {running ? (
          <button
            type="button"
            className="flex items-center gap-1 rounded-md bg-[var(--color-role-error)] px-2.5 py-1 text-xs font-semibold text-white transition-opacity hover:opacity-90"
            data-testid="preview-stop"
            onClick={onStop}
          >
            <Square className="h-3 w-3" />
            Stop
          </button>
        ) : (
          <button
            type="button"
            className="flex items-center gap-1 rounded-md bg-accent px-2.5 py-1 text-xs font-semibold text-[var(--color-accent-foreground)] transition-opacity hover:opacity-90 disabled:opacity-50"
            data-testid="preview-run"
            disabled={!hasScripts || selected === null}
            onClick={onRun}
          >
            <Play className="h-3 w-3" />
            Run
          </button>
        )}
      </div>

      {startError ? (
        <div
          className="border-b border-border-subtle px-3 py-2 text-xs"
          style={{ color: "var(--color-role-error)" }}
          data-testid="preview-error"
        >
          {startError}
        </div>
      ) : null}

      {/* Discovered dev server: a card that embeds it in this panel. */}
      {server ? (
        <button
          type="button"
          className="flex items-center gap-2 border-b border-border-subtle bg-surface px-3 py-2 text-left transition-colors hover:bg-[var(--color-hover-fill)]"
          data-testid="preview-server-card"
          onClick={() => onOpenServer(server.url)}
        >
          <span className="inline-block h-2 w-2 shrink-0 rounded-full bg-[var(--color-success)]" />
          <span className="min-w-0 flex-1">
            <span className="block text-xs font-semibold text-text-primary">Dev server ready</span>
            <span className="block truncate font-mono text-[11px] text-text-muted">
              {server.url}
            </span>
          </span>
          <ExternalLink className="h-3.5 w-3.5 shrink-0 text-text-muted" />
        </button>
      ) : null}

      {/* Output log, or the empty state. */}
      {log.length > 0 ? (
        <div
          className="min-h-0 flex-1 overflow-y-auto whitespace-pre-wrap break-words bg-surface px-3 py-2 font-mono text-[11px] leading-relaxed text-text-secondary"
          data-testid="preview-log"
        >
          {log}
          <div ref={logEndRef} />
        </div>
      ) : (
        <div
          className="flex min-h-0 flex-1 flex-col items-center justify-center gap-2 px-6 text-center"
          data-testid="preview-empty"
        >
          <p className="text-sm text-text-secondary">
            {hasScripts ? "No preview yet" : "No scripts to run"}
          </p>
          <p className="text-xs text-text-muted">
            {hasScripts
              ? "Run a dev script — a listening localhost port opens here automatically."
              : "This project has no package.json scripts to run."}
          </p>
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// The embedded browser (preview state): the donor's PreviewChromeRow + the
// iframe, condensed — a URL bar, reload, open-in-system-browser, a loading
// overlay and a "still starting?" hint.
// ---------------------------------------------------------------------------

function PreviewBrowser(props: {
  url: string;
  onNavigate: (url: string) => void;
  onBack: () => void;
  onClose: () => void;
}) {
  const { url, onNavigate, onBack, onClose } = props;
  const [draft, setDraft] = useState(url);
  const [focused, setFocused] = useState(false);
  const [loading, setLoading] = useState(true);
  const [showHint, setShowHint] = useState(false);
  // Bumped to force the iframe to remount (a hard reload of the same URL).
  const [reloadNonce, setReloadNonce] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);

  // The embed-boundary guard: whatever the URL's provenance (typed, or a
  // discovered-server frame off the wire), it only ever becomes an iframe src
  // if it is a loopback http(s) origin. The URL bar already rejects non-loopback
  // input; this is the belt-and-suspenders check at the actual embed point, so a
  // non-loopback `url` (a buggy/compromised server frame) renders a blocked
  // notice instead of framing arbitrary external content inside the app window.
  const safeSrc = toLoopbackEmbedUrl(url);

  // Re-seed the draft + reset loading whenever the embedded URL changes.
  useEffect(() => {
    setDraft(url);
    setLoading(true);
    setShowHint(false);
  }, [url, reloadNonce]);

  // Surface a "dev server may still be starting" hint if the frame keeps
  // spinning (an iframe fires no reliable cross-origin error event).
  useEffect(() => {
    if (!loading) return;
    const timer = setTimeout(() => setShowHint(true), IFRAME_LOAD_HINT_MS);
    return () => clearTimeout(timer);
  }, [loading, reloadNonce]);

  const submit = useCallback(
    (event?: FormEvent) => {
      event?.preventDefault();
      const next = toLoopbackEmbedUrl(draft);
      if (next === null) return; // not a loopback http(s) URL — reject the nav
      inputRef.current?.blur();
      if (next === url) setReloadNonce((n) => n + 1);
      else onNavigate(next);
    },
    [draft, url, onNavigate],
  );

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      {/* Chrome row: back to scripts, URL bar, reload, open-external, close. */}
      <form
        onSubmit={submit}
        className="flex items-center gap-1 border-b border-border-subtle px-2 py-1.5"
      >
        <button
          type="button"
          className="shrink-0 rounded p-1 text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
          title="Back to scripts"
          aria-label="Back to scripts"
          data-testid="preview-back"
          onClick={onBack}
        >
          <ArrowLeft className="h-3.5 w-3.5" />
        </button>
        <button
          type="button"
          className="shrink-0 rounded p-1 text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
          title="Reload"
          aria-label="Reload"
          data-testid="preview-reload"
          onClick={() => setReloadNonce((n) => n + 1)}
        >
          <RotateCw className={cn("h-3.5 w-3.5", loading && "animate-spin")} />
        </button>
        <input
          ref={inputRef}
          className="min-w-0 flex-1 rounded-md border border-border-subtle bg-surface px-2 py-1 font-mono text-[11px] text-text-primary focus:border-accent focus:outline-none"
          data-testid="preview-url-input"
          value={draft}
          spellCheck={false}
          onChange={(event) => setDraft(event.target.value)}
          onFocus={() => setFocused(true)}
          onBlur={() => {
            setFocused(false);
            setDraft(url);
          }}
          onKeyDown={(event) => {
            if (event.key === "Escape") {
              event.preventDefault();
              setDraft(url);
              inputRef.current?.blur();
            }
          }}
          aria-label="Preview URL"
          placeholder="http://localhost:3000"
        />
        <button
          type="button"
          className="shrink-0 rounded p-1 text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
          title="Open in system browser"
          aria-label="Open in system browser"
          data-testid="preview-open-external"
          onClick={() => window.open(url, "_blank", "noopener,noreferrer")}
        >
          <ExternalLink className="h-3.5 w-3.5" />
        </button>
        <button
          type="button"
          className="shrink-0 rounded p-1 text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
          title="Close preview panel"
          aria-label="Close preview panel"
          data-testid="preview-close"
          onClick={onClose}
        >
          <X className="h-3.5 w-3.5" />
        </button>
      </form>

      {/* The embed. A plain iframe works in the browser AND the Electron shell;
          it never leaks the parent origin (cross-origin isolation). The sandbox
          keeps the embedded dev server contained: scripts/forms/same-origin run
          normally, but top-navigation, popups, and downloads are withheld so a
          click inside the site can't bust out of the panel or hijack the app
          window (critical in the Electron renderer). */}
      <div className="relative min-h-0 flex-1 bg-white">
        {safeSrc === null ? (
          <div
            className="flex h-full w-full items-center justify-center bg-surface p-6 text-center text-sm text-text-muted"
            data-testid="preview-blocked"
          >
            Only a loopback (localhost) dev server can be embedded here.
          </div>
        ) : (
          <iframe
            key={`${safeSrc}#${reloadNonce}`}
            src={safeSrc}
            title="Dev server preview"
            data-testid="preview-iframe"
            className="h-full w-full border-0"
            sandbox="allow-scripts allow-forms allow-same-origin"
            onLoad={() => {
              setLoading(false);
              setShowHint(false);
            }}
          />
        )}
        {safeSrc !== null && loading ? (
          <div
            className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center gap-2 bg-surface"
            data-testid="preview-loading"
            aria-hidden={!focused}
          >
            <RotateCw className="h-5 w-5 animate-spin text-text-muted" />
            <span className="text-xs text-text-muted">
              {showHint ? "The dev server may still be starting…" : "Loading…"}
            </span>
          </div>
        ) : null}
      </div>
    </div>
  );
}
