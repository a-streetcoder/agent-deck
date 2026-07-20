import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type PointerEvent as ReactPointerEvent,
} from "react";
import { ChevronDown, Trash2 } from "lucide-react";
import { FitAddon } from "@xterm/addon-fit";
import { Terminal, type ITheme } from "@xterm/xterm";
import "@xterm/xterm/css/xterm.css";
import { useAppStore } from "../state/store.ts";
import {
  closeSessionTerminal,
  openSessionTerminal,
  sendTerminalInput,
  sendTerminalResize,
  subscribeTerminalPush,
} from "../state/wsBridge.ts";

/**
 * The per-session terminal drawer (Slice 8b), ported from t3code's
 * `ThreadTerminalDrawer.tsx` (MIT) and condensed to our surface: ONE terminal
 * per session (no splits/groups/tabs), our zustand store instead of atoms, our
 * RPC transport instead of the donor's atom commands. What survives the port
 * is the drawer's shape and behavior: a resizable bottom drawer on the session
 * view, xterm + FitAddon rendering, focus-on-open, fit-on-resize, and the
 * "closing hides, the shell survives" contract — reopening reattaches by
 * terminal id and the server replays the scrollback.
 *
 * Lifecycle: the xterm instance exists only while the drawer is OPEN for a
 * given session. Opening lazily creates (or reattaches to) the server PTY;
 * closing the drawer disposes only the renderer. The PTY itself dies with its
 * session, its connection, or the explicit kill button — a session that never
 * opens the drawer never spawns a shell.
 */

const DEFAULT_DRAWER_HEIGHT = 260;
const MIN_DRAWER_HEIGHT = 160;
const MAX_DRAWER_HEIGHT_RATIO = 0.75;

function clampDrawerHeight(height: number): number {
  const max = Math.max(MIN_DRAWER_HEIGHT, Math.floor(window.innerHeight * MAX_DRAWER_HEIGHT_RATIO));
  const safe = Number.isFinite(height) ? Math.round(height) : DEFAULT_DRAWER_HEIGHT;
  return Math.min(Math.max(safe, MIN_DRAWER_HEIGHT), max);
}

/** Read a design token off :root, with a fallback for detached test DOMs. */
function tokenColor(name: string, fallback: string): string {
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  return value.length > 0 ? value : fallback;
}

/**
 * xterm theme from our design tokens; the ANSI ramp is the donor's dark
 * palette (terminalThemeFromApp, MIT) — it reads well on our dark surface.
 */
function terminalTheme(): ITheme {
  return {
    background: tokenColor("--color-surface", "#1e1e20"),
    foreground: tokenColor("--color-text-primary", "#ededf0"),
    cursor: tokenColor("--color-brand-accent", "#64d2ff"),
    selectionBackground: "rgba(100, 210, 255, 0.25)",
    black: "rgb(24, 30, 38)",
    red: "rgb(255, 122, 142)",
    green: "rgb(134, 231, 149)",
    yellow: "rgb(244, 205, 114)",
    blue: "rgb(137, 190, 255)",
    magenta: "rgb(208, 176, 255)",
    cyan: "rgb(124, 232, 237)",
    white: "rgb(210, 218, 230)",
    brightBlack: "rgb(110, 120, 136)",
    brightRed: "rgb(255, 168, 180)",
    brightGreen: "rgb(176, 245, 186)",
    brightYellow: "rgb(255, 224, 149)",
    brightBlue: "rgb(174, 210, 255)",
    brightMagenta: "rgb(229, 203, 255)",
    brightCyan: "rgb(167, 244, 247)",
    brightWhite: "rgb(244, 247, 252)",
  };
}

function fitSafely(fitAddon: FitAddon): void {
  try {
    fitAddon.fit();
  } catch {
    // A zero-sized container mid-layout: the next resize observation refits.
  }
}

export function TerminalDrawer() {
  const open = useAppStore((state) => state.terminalOpen);
  const setTerminalOpen = useAppStore((state) => state.setTerminalOpen);
  const sessionId = useAppStore((state) => state.session?.id ?? null);
  const connection = useAppStore((state) => state.connection);

  const containerRef = useRef<HTMLDivElement>(null);
  const [height, setHeight] = useState(DEFAULT_DRAWER_HEIGHT);
  const heightRef = useRef(height);
  heightRef.current = height;
  const resizeStateRef = useRef<{ pointerId: number; startY: number; startHeight: number } | null>(
    null,
  );

  // ---------------------------------------------------------------------
  // xterm lifecycle: one renderer per (open, session, connection) episode.
  // Reconnects re-run it (a drop killed the server PTY; reattach or respawn).
  // ---------------------------------------------------------------------
  const connected = connection === "open";
  useEffect(() => {
    const mount = containerRef.current;
    if (!open || !sessionId || !connected || !mount) return;

    const fitAddon = new FitAddon();
    const terminal = new Terminal({
      cursorBlink: false,
      fontSize: 12,
      scrollback: 5_000,
      // Our --font-mono stack, inlined: xterm measures glyph metrics off this
      // string, so it must resolve without CSS-variable indirection.
      fontFamily:
        '"JetBrains Mono Variable", ui-monospace, SFMono-Regular, "Cascadia Mono", Consolas, monospace',
      theme: terminalTheme(),
    });
    terminal.loadAddon(fitAddon);
    terminal.open(mount);
    fitSafely(fitAddon);

    let disposed = false;
    let terminalId: string | null = null;

    // Push ordering note: frames arrive in socket order, and the open promise
    // resolves in a microtask BEFORE the next frame's task runs — so every
    // chunk of the new attachment is processed with `terminalId` already set.
    // Pushes seen while `terminalId` is null belong to a PREVIOUS attachment
    // (reopen while output streams); those chunks are already inside the
    // scrollback the reply replays, so they are dropped, not buffered —
    // buffering would double-write them.
    const unsubscribePush = subscribeTerminalPush((message) => {
      if (message.terminalId !== terminalId) return;
      if (message.type === "terminal_output") {
        terminal.write(message.data);
        return;
      }
      terminal.write(`\r\n[terminal] exited (code ${message.exitCode ?? "?"})\r\n`);
    });

    const inputDisposable = terminal.onData((data) => {
      if (terminalId !== null) sendTerminalInput(terminalId, data);
    });

    // The toggle shortcut (⌘`/Ctrl+`) must bubble to the app while the
    // terminal owns focus; everything else stays with the shell (donor's
    // attachCustomKeyEventHandler contract).
    terminal.attachCustomKeyEventHandler((event) => {
      if ((event.ctrlKey || event.metaKey) && event.key === "`") return false;
      return true;
    });

    // Fit on every container size change (drawer drag, window resize) and
    // propagate the new grid to the PTY.
    const refit = (): void => {
      if (disposed) return;
      const before = { cols: terminal.cols, rows: terminal.rows };
      fitSafely(fitAddon);
      if (terminalId !== null && (terminal.cols !== before.cols || terminal.rows !== before.rows)) {
        sendTerminalResize(terminalId, terminal.cols, terminal.rows);
      }
    };
    let resizeFrame: number | null = null;
    const observer = new ResizeObserver(() => {
      if (resizeFrame !== null) cancelAnimationFrame(resizeFrame);
      resizeFrame = requestAnimationFrame(() => {
        resizeFrame = null;
        refit();
      });
    });
    observer.observe(mount);

    void openSessionTerminal(terminal.cols, terminal.rows)
      .then((result) => {
        if (disposed) return;
        terminalId = result.terminalId;
        if (result.scrollback.length > 0) terminal.write(result.scrollback);
        if (!result.running) terminal.write("\r\n[terminal] exited\r\n");
        // The PTY grid may predate this drawer size (reattach): re-sync it.
        sendTerminalResize(result.terminalId, terminal.cols, terminal.rows);
        terminal.focus();
      })
      .catch((error: unknown) => {
        if (disposed) return;
        terminal.write(`\r\n[terminal] failed to open: ${String(error)}\r\n`);
      });

    return () => {
      disposed = true;
      if (resizeFrame !== null) cancelAnimationFrame(resizeFrame);
      observer.disconnect();
      unsubscribePush();
      inputDisposable.dispose();
      terminal.dispose();
    };
  }, [open, sessionId, connected]);

  // ---------------------------------------------------------------------
  // Drag-to-resize (donor's pointer-capture handle, condensed).
  // ---------------------------------------------------------------------
  const onHandlePointerDown = useCallback((event: ReactPointerEvent<HTMLDivElement>) => {
    if (event.button !== 0) return;
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);
    resizeStateRef.current = {
      pointerId: event.pointerId,
      startY: event.clientY,
      startHeight: heightRef.current,
    };
  }, []);
  const onHandlePointerMove = useCallback((event: ReactPointerEvent<HTMLDivElement>) => {
    const state = resizeStateRef.current;
    if (!state || state.pointerId !== event.pointerId) return;
    event.preventDefault();
    setHeight(clampDrawerHeight(state.startHeight + (state.startY - event.clientY)));
  }, []);
  const onHandlePointerEnd = useCallback((event: ReactPointerEvent<HTMLDivElement>) => {
    const state = resizeStateRef.current;
    if (!state || state.pointerId !== event.pointerId) return;
    resizeStateRef.current = null;
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }
  }, []);

  if (!open || !sessionId) return null;

  return (
    <aside
      data-terminal-owner="drawer"
      data-testid="terminal-drawer"
      className="relative flex shrink-0 flex-col overflow-hidden border-t border-border-subtle bg-surface"
      style={{ height: `${height}px` }}
    >
      <div
        className="absolute inset-x-0 top-0 z-10 h-1.5 cursor-row-resize"
        data-testid="terminal-resize-handle"
        onPointerDown={onHandlePointerDown}
        onPointerMove={onHandlePointerMove}
        onPointerUp={onHandlePointerEnd}
        onPointerCancel={onHandlePointerEnd}
      />
      <div className="flex items-center justify-between border-b border-border-subtle bg-surface-elevated px-3 py-1">
        <span className="text-xs font-semibold uppercase tracking-wide text-text-muted">
          Terminal
        </span>
        <div className="flex items-center gap-1">
          <button
            type="button"
            className="rounded p-1 text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
            title="Kill terminal"
            aria-label="Kill terminal"
            data-testid="terminal-kill"
            onClick={() => {
              closeSessionTerminal(sessionId);
              setTerminalOpen(false);
            }}
          >
            <Trash2 className="h-3.5 w-3.5" />
          </button>
          <button
            type="button"
            className="rounded p-1 text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
            title="Hide terminal (⌘`)"
            aria-label="Hide terminal"
            data-testid="terminal-hide"
            onClick={() => setTerminalOpen(false)}
          >
            <ChevronDown className="h-3.5 w-3.5" />
          </button>
        </div>
      </div>
      <div className="min-h-0 flex-1 px-2 py-1">
        <div ref={containerRef} className="h-full w-full overflow-hidden" />
      </div>
    </aside>
  );
}
