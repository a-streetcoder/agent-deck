import { createRequire } from "node:module";
import { TERMINAL_MAX_OUTPUT_CHUNK, TERMINAL_MAX_SCROLLBACK_CHARS } from "@agent-deck/contracts";
import { Context, Data, Deferred, Duration, Effect, Layer, Option, type Scope } from "effect";
import { sanitizeTerminalHistoryChunk } from "./terminalScrollback.ts";

/**
 * TerminalHost as a scoped Effect service (Slice 8a): the per-session
 * integrated-terminal PTY lifecycle. Ported from t3code's
 * `apps/server/src/terminal/{Manager.ts,PtyAdapter.ts,NodePtyAdapter.ts}` (MIT)
 * and re-expressed in this repo's service idioms — services/piHost.ts is the
 * template (a factory service handing out Scope-owned process handles), and
 * this file is its sibling: where piHost owns a pi subprocess over JSONL
 * stdio, TerminalHost owns a shell subprocess over a PTY.
 *
 * File anatomy (the pushBus/piHost template):
 *   1. adapter seam + data types + handle interface (effectful API surface)
 *   2. `spawnTerminal` — the scoped acquire/release implementation
 *   3. `Context.Tag` service class
 *   4. `TerminalHostLive` Layer — joined into `serverLayers` in ../runtime.ts
 *
 * ## The PtyAdapter seam (donor design, lifted near-verbatim)
 *
 * The donor isolates node-pty behind a `PtyAdapter` interface so the manager
 * is testable with a scripted fake; we keep exactly that seam. The default
 * adapter loads `node-pty` lazily via `createRequire` on first spawn (it is a
 * native module — loading at import time would make every server test pay the
 * DLL load, and a broken native build would poison unrelated code paths).
 *
 * ## Scope-owned PTY (acquireRelease)
 *
 * `spawnTerminal` is a SCOPED resource, exactly like `spawnPiProcess`:
 *   - acquire: resolve the shell candidate list (donor's fallback chain:
 *     pwsh → Windows PowerShell → ComSpec/cmd on win32; $SHELL → zsh → bash →
 *     sh elsewhere), spawn through the adapter — trying the next candidate on
 *     a spawn throw — and wire onData/onExit BEFORE returning, so no output
 *     or exit can be missed.
 *   - release: kill the PTY (kill → grace → SIGKILL, the donor's escalation)
 *     and wait for the real exit, bounded by the grace so release can never
 *     hang. Closing the owning scope therefore ALWAYS tears the PTY down —
 *     terminal_close, the owning WS connection dropping, and session close
 *     all funnel into one scope close (no orphan PTYs).
 *
 * ## Scrollback + attach semantics (donor semantics, simplified surface)
 *
 * Output is accumulated into a bounded scrollback buffer (capped by
 * characters, `TERMINAL_MAX_SCROLLBACK_CHARS`, trimmed from the front) so a
 * late-attaching/re-subscribing client gets the buffer. The buffered text is
 * SANITIZED first (terminalScrollback.ts, the donor's history sanitizer):
 * terminal query/report sequences are stripped so a replay never makes the
 * client's xterm re-answer them into the live shell. `attach` is a SINGLE
 * `Effect.sync` op that snapshots the scrollback and subscribes atomically —
 * the same single-op-atomicity argument as pushBus: a fiber cannot yield
 * inside one sync op and the PTY callbacks are macro-task events, so no chunk
 * can land between the snapshot and the subscription (nothing is ever
 * double-delivered or dropped).
 *
 * ## Bridging from node-pty callbacks
 *
 * Like piHost: PTY data/exit arrive through synchronous callbacks; they touch
 * only closure-scoped mutable state (scrollback string, listener Set, exit
 * Option) and the sanctioned sync bridge `Deferred.unsafeDone` — no runSync,
 * no runtime capture. Listeners are plain sync callbacks (the pushBus
 * convention) because the consumer (rpcHandler) is the synchronous frame
 * writer. Chunks larger than the wire bound are split BEFORE dispatch so
 * every emitted chunk is contract-valid (`TERMINAL_MAX_OUTPUT_CHUNK`).
 */

// ---------------------------------------------------------------------------
// 1. Adapter seam + data types
// ---------------------------------------------------------------------------

/** Exit record delivered by the PTY (node-pty `IExitEvent` shape, null-normalized). */
export interface TerminalExit {
  readonly exitCode: number | null;
  readonly signal: number | null;
}

/**
 * The process primitives terminal management needs, without binding to a
 * specific PTY implementation — t3code's `PtyAdapter.PtyProcess` seam (MIT).
 */
export interface PtyProcessLike {
  readonly pid: number;
  write(data: string): void;
  resize(cols: number, rows: number): void;
  kill(signal?: string): void;
  /** Pause the PTY's output flow (socket backpressure). */
  pause(): void;
  /** Resume the PTY's output flow after a pause. */
  resume(): void;
  /** Register a data callback; returns the disposer. */
  onData(callback: (data: string) => void): () => void;
  /** Register an exit callback; returns the disposer. */
  onExit(callback: (event: TerminalExit) => void): () => void;
}

export interface PtySpawnInput {
  readonly shell: string;
  readonly args: readonly string[];
  readonly cwd: string;
  readonly cols: number;
  readonly rows: number;
  readonly env: Record<string, string>;
}

/** The spawn seam: `spawn` may THROW (adapter contract); callers wrap it. */
export interface PtyAdapter {
  spawn(input: PtySpawnInput): PtyProcessLike;
}

/** One shell candidate in the donor's fallback chain. */
export interface ShellCandidate {
  readonly shell: string;
  readonly args?: readonly string[];
}

export const DEFAULT_TERMINAL_COLS = 120;
export const DEFAULT_TERMINAL_ROWS = 30;
/** kill → this grace → SIGKILL, and the release-wait bound (donor: 1s). */
const KILL_GRACE_MS = 1_000;

/**
 * Env keys terminals must NOT inherit from the server process (donor's
 * TERMINAL_ENV_BLOCKLIST): dev-server/electron plumbing that would confuse
 * tools launched from the shell.
 */
const TERMINAL_ENV_BLOCKLIST = new Set(["PORT", "ELECTRON_RENDERER_PORT", "ELECTRON_RUN_AS_NODE"]);

/** Every candidate in the fallback chain failed to spawn. */
export class TerminalSpawnFailed extends Data.TaggedError("TerminalSpawnFailed")<{
  readonly attempted: readonly string[];
  readonly cause: unknown;
}> {
  override get message(): string {
    return `failed to spawn a terminal shell (tried: ${this.attempted.join(", ")})`;
  }
}

/** A write/resize hit a PTY that already exited. */
export class TerminalExited extends Data.TaggedError("TerminalExited")<{
  readonly exit: Option.Option<TerminalExit>;
}> {
  override get message(): string {
    const exit = Option.getOrUndefined(this.exit);
    return `terminal already exited (code=${exit?.exitCode ?? "?"}, signal=${exit?.signal ?? "?"})`;
  }
}

/** One event delivered to an attached listener. */
export type TerminalEvent =
  | { readonly _tag: "Output"; readonly data: string }
  | { readonly _tag: "Exit"; readonly exit: TerminalExit };

/** The atomic result of `attach`: buffer snapshot + live subscription. */
export interface TerminalAttachment {
  /** Scrollback accumulated BEFORE this attach (capped — see module doc). */
  readonly scrollback: string;
  readonly running: boolean;
  readonly unsubscribe: () => void;
}

/** One live terminal PTY as a scoped resource. */
export interface TerminalHandle {
  readonly pid: number;
  /** The shell command that actually spawned (diagnostics/labeling). */
  readonly shell: string;
  /** Write input bytes to the PTY. Fails typed once the PTY has exited. */
  readonly write: (data: string) => Effect.Effect<void, TerminalExited>;
  /** Resize the PTY. Fails typed once the PTY has exited. */
  readonly resize: (cols: number, rows: number) => Effect.Effect<void, TerminalExited>;
  /**
   * Snapshot the scrollback and subscribe to subsequent events, atomically
   * (single sync op — nothing can slip between snapshot and subscription).
   * Multiple listeners may attach; each gets every later chunk once.
   */
  readonly attach: (listener: (event: TerminalEvent) => void) => Effect.Effect<TerminalAttachment>;
  /**
   * Pause/resume the PTY's output flow — the consumer-side backpressure valve
   * (rpcHandler pauses when the client socket's send buffer backs up). No-ops
   * once the PTY has exited or when the underlying PTY refuses.
   */
  readonly pause: Effect.Effect<void>;
  readonly resume: Effect.Effect<void>;
  readonly isRunning: Effect.Effect<boolean>;
  /** The exit record once the PTY has exited (None while running). */
  readonly exit: Effect.Effect<Option.Option<TerminalExit>>;
  /** Resolves when the PTY exits (immediately if it already has). */
  readonly awaitExit: Effect.Effect<TerminalExit>;
}

export interface TerminalSpawnOptions {
  /** Working directory — the owning session's cwd (worktree-aware `meta.cwd`). */
  readonly cwd: string;
  readonly cols?: number;
  readonly rows?: number;
  /** Base environment (defaults to `process.env`); the blocklist is applied on top. */
  readonly env?: Record<string, string | undefined>;
  /**
   * Override the shell fallback chain (tests). Defaults to the donor's
   * platform pick: pwsh → Windows PowerShell → ComSpec/cmd on win32,
   * $SHELL → zsh → bash → sh elsewhere.
   */
  readonly shellCandidates?: readonly ShellCandidate[];
  /** Scrollback cap in characters (tests); defaults to the wire-contract cap. */
  readonly maxScrollbackChars?: number;
}

// ---------------------------------------------------------------------------
// Shell candidate resolution (donor: Manager.ts resolveShellCandidates, MIT)
// ---------------------------------------------------------------------------

const windowsSystemRoot = (env: Record<string, string | undefined>): string =>
  env.SystemRoot?.trim() || env.windir?.trim() || "C:\\Windows";

/**
 * The donor's platform shell chain, condensed: every candidate is tried in
 * order until one spawns. `-NoLogo` on the PowerShells mirrors the donor.
 *
 * `AGENT_DECK_TERMINAL_SHELL`, when set, is prepended as the FIRST candidate
 * (the e2e/visual-test seam: the harness forces `cmd.exe` + a fixed `PROMPT`
 * so terminal output is deterministic). A bad override falls through to the
 * platform chain like any other failed candidate.
 */
export function defaultShellCandidates(
  platform: NodeJS.Platform,
  env: Record<string, string | undefined>,
): ShellCandidate[] {
  const candidates: Array<ShellCandidate | null> = [];
  candidates.push(env.AGENT_DECK_TERMINAL_SHELL ? { shell: env.AGENT_DECK_TERMINAL_SHELL } : null);
  if (platform === "win32") {
    const systemRoot = windowsSystemRoot(env);
    candidates.push(
      { shell: "pwsh.exe", args: ["-NoLogo"] },
      {
        shell: `${systemRoot}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe`,
        args: ["-NoLogo"],
      },
      { shell: "powershell.exe", args: ["-NoLogo"] },
      env.ComSpec ? { shell: env.ComSpec } : null,
      { shell: "cmd.exe" },
    );
  } else {
    candidates.push(
      env.SHELL ? { shell: env.SHELL } : null,
      { shell: "/bin/zsh" },
      { shell: "/bin/bash" },
      { shell: "/bin/sh" },
      { shell: "bash" },
      { shell: "sh" },
    );
  }
  const seen = new Set<string>();
  const unique: ShellCandidate[] = [];
  for (const candidate of candidates) {
    if (!candidate) continue;
    const trimmed = candidate.shell.trim();
    if (trimmed.length === 0 || seen.has(trimmed)) continue;
    seen.add(trimmed);
    unique.push({ ...candidate, shell: trimmed });
  }
  return unique;
}

/** Inheritable spawn env: base minus blocklist minus undefined values. */
function buildSpawnEnv(base: Record<string, string | undefined>): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(base)) {
    if (value === undefined) continue;
    if (TERMINAL_ENV_BLOCKLIST.has(key.toUpperCase())) continue;
    env[key] = value;
  }
  return env;
}

/**
 * Cap the scrollback buffer by characters, trimming the oldest output. The cut
 * is rounded to a CODE-POINT boundary: a raw UTF-16 slice can open on the low
 * half of a surrogate pair, and that lone surrogate would render as U+FFFD in
 * every future replay of the buffer.
 */
function capScrollback(buffer: string, maxChars: number): string {
  if (buffer.length <= maxChars) return buffer;
  let start = buffer.length - maxChars;
  const first = buffer.charCodeAt(start);
  if (first >= 0xdc00 && first <= 0xdfff) start += 1; // lone low surrogate
  return buffer.slice(start);
}

// ---------------------------------------------------------------------------
// Default adapter: node-pty (donor: NodePtyAdapter.ts, MIT), loaded lazily
// ---------------------------------------------------------------------------

/**
 * Structural view of the node-pty surface this adapter uses (`IPty` subset).
 * Declared locally instead of `typeof import("node-pty")` so the type layer
 * carries no dependency on the native module (and lint's ban on `import()`
 * type annotations holds).
 */
interface NodePtyDisposable {
  dispose(): void;
}
interface NodePtyProcess {
  readonly pid: number;
  write(data: string): void;
  resize(cols: number, rows: number): void;
  kill(signal?: string): void;
  pause(): void;
  resume(): void;
  onData(callback: (data: string) => void): NodePtyDisposable;
  onExit(callback: (event: { exitCode: number; signal?: number }) => void): NodePtyDisposable;
}
interface NodePtyModule {
  spawn(
    file: string,
    args: string[],
    options: {
      cwd: string;
      cols: number;
      rows: number;
      env: Record<string, string>;
      name: string;
    },
  ): NodePtyProcess;
}

let nodePtyModule: NodePtyModule | null = null;

function loadNodePty(): NodePtyModule {
  if (nodePtyModule === null) {
    // node-pty is CJS with a native binding; createRequire keeps the load
    // synchronous and lazy (first spawn pays it, imports don't).
    const require = createRequire(import.meta.url);
    nodePtyModule = require("node-pty") as NodePtyModule;
  }
  return nodePtyModule;
}

/** The production adapter: node-pty (ConPTY on Windows, forkpty elsewhere). */
export const nodePtyAdapter: PtyAdapter = {
  spawn(input) {
    const pty = loadNodePty();
    const proc = pty.spawn(input.shell, [...input.args], {
      cwd: input.cwd,
      cols: input.cols,
      rows: input.rows,
      env: input.env,
      name: process.platform === "win32" ? "xterm-color" : "xterm-256color",
    });
    return {
      pid: proc.pid,
      write: (data) => proc.write(data),
      resize: (cols, rows) => proc.resize(cols, rows),
      kill: (signal) => proc.kill(process.platform === "win32" ? undefined : signal),
      pause: () => proc.pause(),
      resume: () => proc.resume(),
      onData: (callback) => {
        const disposable = proc.onData(callback);
        return () => disposable.dispose();
      },
      onExit: (callback) => {
        const disposable = proc.onExit((event) =>
          callback({ exitCode: event.exitCode ?? null, signal: event.signal ?? null }),
        );
        return () => disposable.dispose();
      },
    };
  },
};

// ---------------------------------------------------------------------------
// 2. The scoped acquire/release implementation
// ---------------------------------------------------------------------------

/**
 * Spawn one terminal PTY tied to the caller's Scope: closing the scope kills
 * the shell (kill → grace → SIGKILL) and waits (bounded) for the real exit.
 * Fails typed with `TerminalSpawnFailed` when every shell candidate refuses
 * to spawn.
 */
export const spawnTerminal = (
  adapter: PtyAdapter,
  options: TerminalSpawnOptions,
): Effect.Effect<TerminalHandle, TerminalSpawnFailed, Scope.Scope> =>
  Effect.map(
    Effect.acquireRelease(
      Effect.gen(function* () {
        const cols = options.cols ?? DEFAULT_TERMINAL_COLS;
        const rows = options.rows ?? DEFAULT_TERMINAL_ROWS;
        const maxScrollbackChars = options.maxScrollbackChars ?? TERMINAL_MAX_SCROLLBACK_CHARS;
        const env = buildSpawnEnv(options.env ?? process.env);
        const candidates =
          options.shellCandidates ??
          defaultShellCandidates(process.platform, options.env ?? process.env);

        // Donor fallback chain: try each candidate; the last throw is the cause.
        const spawned = yield* Effect.try({
          try: () => {
            let lastError: unknown;
            for (const candidate of candidates) {
              try {
                const proc = adapter.spawn({
                  shell: candidate.shell,
                  args: candidate.args ?? [],
                  cwd: options.cwd,
                  cols,
                  rows,
                  env,
                });
                return { proc, shell: candidate.shell };
              } catch (error) {
                lastError = error;
              }
            }
            throw lastError ?? new Error("no shell candidates");
          },
          catch: (cause) =>
            new TerminalSpawnFailed({ attempted: candidates.map((c) => c.shell), cause }),
        });
        const { proc, shell } = spawned;

        const exitDeferred = yield* Deferred.make<TerminalExit>();

        // Closure-scoped mutable state — only touched inside single sync ops
        // or the synchronous PTY callbacks (see module doc).
        let scrollback = "";
        let pendingControlSequence = "";
        let exitState: Option.Option<TerminalExit> = Option.none();
        const listeners = new Set<(event: TerminalEvent) => void>();

        const dispatch = (event: TerminalEvent): void => {
          for (const listener of listeners) listener(event);
        };

        // Wired BEFORE the handle escapes, so no chunk or exit is missed.
        const disposeData = proc.onData((data) => {
          // Scrollback buffers the SANITIZED text (donor semantics): replayed
          // query/report sequences (CSI 6n, CPR, DA, OSC 10/11/12 — ConPTY
          // emits CSI 6n at startup) would make xterm RE-ANSWER them on
          // reattach, typing garbage into the live shell. Live listeners get
          // the raw bytes — a live terminal must see and answer queries.
          const sanitized = sanitizeTerminalHistoryChunk(pendingControlSequence, data);
          pendingControlSequence = sanitized.pendingControlSequence;
          scrollback = capScrollback(scrollback + sanitized.visibleText, maxScrollbackChars);
          // Split oversized reads so every dispatched chunk is wire-valid,
          // never cutting inside a surrogate pair (a chunk ending on a lone
          // high surrogate would be mangled by JSON encoding).
          for (let i = 0; i < data.length; ) {
            let end = Math.min(i + TERMINAL_MAX_OUTPUT_CHUNK, data.length);
            const last = data.charCodeAt(end - 1);
            if (end < data.length && last >= 0xd800 && last <= 0xdbff) end -= 1;
            dispatch({ _tag: "Output", data: data.slice(i, end) });
            i = end;
          }
        });
        const disposeExit = proc.onExit((exit) => {
          if (Option.isSome(exitState)) return;
          exitState = Option.some(exit);
          Deferred.unsafeDone(exitDeferred, Effect.succeed(exit));
          dispatch({ _tag: "Exit", exit });
        });

        const requireRunning = Effect.suspend(() =>
          Option.isSome(exitState)
            ? Effect.fail(new TerminalExited({ exit: exitState }))
            : Effect.void,
        );

        const handle: TerminalHandle = {
          pid: proc.pid,
          shell,
          write: (data) =>
            requireRunning.pipe(
              Effect.zipRight(
                Effect.try({
                  try: () => proc.write(data),
                  catch: () => new TerminalExited({ exit: exitState }),
                }),
              ),
            ),
          resize: (cols, rows) =>
            requireRunning.pipe(
              Effect.zipRight(
                Effect.try({
                  try: () => proc.resize(cols, rows),
                  catch: () => new TerminalExited({ exit: exitState }),
                }),
              ),
            ),
          attach: (listener) =>
            Effect.sync(() => {
              listeners.add(listener);
              return {
                scrollback,
                running: Option.isNone(exitState),
                unsubscribe: () => {
                  listeners.delete(listener);
                },
              };
            }),
          pause: Effect.sync(() => {
            if (Option.isSome(exitState)) return;
            try {
              proc.pause();
            } catch {
              // PTY already gone — nothing to pause.
            }
          }),
          resume: Effect.sync(() => {
            if (Option.isSome(exitState)) return;
            try {
              proc.resume();
            } catch {
              // PTY already gone — nothing to resume.
            }
          }),
          isRunning: Effect.sync(() => Option.isNone(exitState)),
          exit: Effect.sync(() => exitState),
          awaitExit: Deferred.await(exitDeferred),
        };

        return {
          handle,
          proc,
          isExited: () => Option.isSome(exitState),
          cleanup: () => {
            disposeData();
            disposeExit();
          },
        };
      }),
      // Release: donor kill escalation, bounded so scope close can never hang.
      ({ handle, proc, isExited, cleanup }) =>
        Effect.gen(function* () {
          const killed = (signal?: string): boolean => {
            try {
              proc.kill(signal);
              return true;
            } catch {
              return false; // already gone (or unkillable) — nothing to escalate
            }
          };
          // Finalizers run uninterruptibly, which would neuter an
          // interruption-based timeout: the Deferred.await must be explicitly
          // re-marked interruptible for Effect.timeout to cut it short.
          const awaitExitBounded = Effect.interruptible(handle.awaitExit).pipe(
            Effect.timeout(Duration.millis(KILL_GRACE_MS)),
          );
          if (!isExited() && killed("SIGTERM")) {
            yield* awaitExitBounded.pipe(
              Effect.catchAll(() =>
                Effect.suspend(() => {
                  if (!isExited()) killed("SIGKILL");
                  return Effect.ignore(awaitExitBounded);
                }),
              ),
            );
          }
          // The bounded escalation means release CAN return with the process
          // still alive (a wedged ConPTY ignoring both kills). Disposing the
          // listeners below makes such a shell invisible to every reaping
          // path — log the pid so the orphan is at least observable.
          if (!isExited()) {
            console.error(
              `terminal: pid ${proc.pid} survived SIGTERM+SIGKILL escalation — ` +
                "abandoning to keep scope close bounded (process may be leaked)",
            );
          }
          cleanup();
        }),
    ),
    ({ handle }) => handle,
  );

// ---------------------------------------------------------------------------
// 3. Service tag + 4. Live layer
// ---------------------------------------------------------------------------

export interface TerminalHostShape {
  /** Spawn a terminal PTY as a resource of the caller's Scope. */
  readonly spawn: (
    options: TerminalSpawnOptions,
  ) => Effect.Effect<TerminalHandle, TerminalSpawnFailed, Scope.Scope>;
}

/**
 * Factory service: terminals are per-session/per-connection, so the
 * runtime-scoped service hands out scoped handles rather than owning PTYs
 * itself (the PiHost pattern).
 */
export class TerminalHost extends Context.Tag("agent-deck/server/services/TerminalHost")<
  TerminalHost,
  TerminalHostShape
>() {}

export const makeTerminalHost = (adapter: PtyAdapter): TerminalHostShape => ({
  spawn: (options) => spawnTerminal(adapter, options),
});

export const TerminalHostLive = Layer.succeed(TerminalHost, makeTerminalHost(nodePtyAdapter));
