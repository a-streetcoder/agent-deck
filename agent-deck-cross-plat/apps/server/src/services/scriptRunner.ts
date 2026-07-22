import { spawn as nodeSpawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { connect as netConnect } from "node:net";
import nodePath from "node:path";
import {
  SCRIPT_MAX_OUTPUT_CHUNK,
  SCRIPT_MAX_SCRIPTS,
  SCRIPT_MAX_SCROLLBACK_CHARS,
  type DiscoveredServer,
  type ProjectScript,
} from "@agent-deck/contracts";
import { Context, Data, Deferred, Duration, Effect, Layer, Option, type Scope } from "effect";
import { TERMINAL_ENV_BLOCKLIST } from "./terminal.ts";

/**
 * ScriptRunner as a scoped Effect service (Slice 15a): run a session project's
 * DECLARED scripts as managed child processes, stream their merged output, and
 * detect the loopback dev-server URL they start listening on. Ported from
 * t3code's `apps/server/src/{preview,project,environment}/` (MIT) — the donor's
 * PortScanner + ProjectSetupScriptRunner — and re-expressed in this repo's
 * service idioms. services/terminal.ts is the direct template: where TerminalHost
 * owns a shell PTY, ScriptRunner owns a plain child process; both are PiHost
 * siblings (a factory handing out Scope-owned process handles).
 *
 * File anatomy (the terminal.ts template):
 *   1. adapter seam + data types + handle interface
 *   2. `listProjectScripts` / `resolveScriptCommand` — the declared-script source
 *   3. port detection (loopback URL scan + loopback TCP probe)
 *   4. `spawnScript` — the scoped acquire/release implementation
 *   5. `Context.Tag` service class + `ScriptRunnerLive` Layer
 *
 * ## Script source + the security boundary (donor's allowed set)
 *
 * A run's command is NEVER supplied by the client — only a `scriptName`. The
 * server resolves it against the project's `package.json` `scripts` map
 * ({@link resolveScriptCommand}); an unknown name fails typed. The resolved
 * command runs through the platform shell (like the donor writing `script.command`
 * into a terminal), with the project's `node_modules/.bin` prepended to PATH so a
 * declared `"dev": "vite"` behaves exactly as `npm run dev` would. Shell
 * metacharacters in the command are the REPO's code — the same trust boundary pi
 * already runs under — so `shell: true` is safe here; the closed door is the
 * client, which can only pick a declared name.
 *
 * ## Port detection + loopback validation (donor: PortScanner, re-attributed)
 *
 * The donor scans ALL listening sockets (`lsof` / `Get-NetTCPConnection`) and
 * maps them to a terminal's process TREE — a strong "this port belongs to this
 * run" guarantee. We use a lighter heuristic: detect the port from a loopback
 * URL the run prints on its OWN stdout ({@link extractLoopbackPorts}), then
 * CONFIRM something is listening with a TCP connect to `127.0.0.1:port`.
 *
 * What this DOES guarantee: the embedded origin is always loopback. A printed
 * non-loopback origin (a LAN IP, a domain) never matches, and the confirm probe
 * only connects to loopback — a script can never make the UI embed an arbitrary
 * external origin (the client also re-validates loopback at the iframe boundary).
 *
 * What it does NOT guarantee: that the confirmed listener is THIS run's own
 * process. If the script prints a loopback URL for a *different* already-running
 * service (a proxy target `→ http://localhost:8080`, a DB `localhost:5432`), the
 * blind connect confirms it and we'd report that unrelated loopback port. Bounded
 * to loopback and visible to the user, but a real limitation. TODO: adopt the
 * donor's socket→process-tree mapping (Get-NetTCPConnection OwningProcess on
 * win32) to bind the port to this run's own PID tree — deferred from Slice 15.
 *
 * ## Scope-owned child (acquireRelease), streaming, tree-kill
 *
 * `spawnScript` is a SCOPED resource, exactly like `spawnTerminal`: acquire spawns
 * through the adapter and wires onData/onExit before returning; release tree-kills
 * the child (SIGTERM → grace → SIGKILL, bounded so scope close never hangs). A
 * dev server forks children (esbuild, workers); the adapter kills the whole tree
 * (POSIX process group / Windows `taskkill /T`) so nothing is orphaned. Output is
 * accumulated into a bounded scrollback (capped by characters) replayed on
 * reattach, and oversized reads are split into wire-valid chunks before dispatch.
 */

// ---------------------------------------------------------------------------
// 1. Adapter seam + data types
// ---------------------------------------------------------------------------

/** Exit record delivered by the child process (`ChildProcess` 'exit' shape). */
export interface ScriptExit {
  readonly exitCode: number | null;
  readonly signal: string | null;
}

/**
 * The process primitives the script runner needs, without binding to
 * `node:child_process` — the terminal.ts PtyAdapter seam, for a plain child.
 */
export interface ScriptProcessLike {
  readonly pid: number;
  /** Tree-kill the child (its whole process group). Safe to call repeatedly. */
  kill(signal: "SIGTERM" | "SIGKILL"): void;
  /** Register a merged-stdout+stderr data callback; returns the disposer. */
  onData(callback: (data: string) => void): () => void;
  /** Register an exit callback; returns the disposer. */
  onExit(callback: (event: ScriptExit) => void): () => void;
}

export interface ScriptSpawnInput {
  /** The declared command string (resolved server-side; never client-supplied). */
  readonly command: string;
  readonly cwd: string;
  readonly env: Record<string, string>;
}

/** The spawn seam: `spawn` may THROW (adapter contract); callers wrap it. */
export interface ScriptAdapter {
  spawn(input: ScriptSpawnInput): ScriptProcessLike;
}

/** kill → this grace → SIGKILL, and the release-wait bound (terminal parity). */
const KILL_GRACE_MS = 1_000;
/** How long a loopback confirm probe waits before giving up (per attempt). */
const PROBE_TIMEOUT_MS = 1_000;

/** The child spawn failed (bad shell / spawn throw). */
export class ScriptSpawnFailed extends Data.TaggedError("ScriptSpawnFailed")<{
  readonly command: string;
  readonly cause: unknown;
}> {
  override get message(): string {
    return `failed to spawn script process (${this.command})`;
  }
}

/** The requested script name is not declared in the project's package.json. */
export class ScriptNotDeclared extends Data.TaggedError("ScriptNotDeclared")<{
  readonly scriptName: string;
}> {
  override get message(): string {
    return `no declared script named '${this.scriptName}' in the project`;
  }
}

/** One event delivered to an attached listener. */
export type ScriptEvent =
  | { readonly _tag: "Output"; readonly data: string }
  | { readonly _tag: "Server"; readonly server: DiscoveredServer }
  | { readonly _tag: "Exit"; readonly exit: ScriptExit };

/** The atomic result of `attach`: buffer snapshot + current server + subscription. */
export interface ScriptAttachment {
  /** Merged output accumulated BEFORE this attach (capped — see module doc). */
  readonly scrollback: string;
  readonly running: boolean;
  /** The discovered dev server, if one has been detected+confirmed yet. */
  readonly server: DiscoveredServer | null;
  readonly unsubscribe: () => void;
}

/** One live script run as a scoped resource. */
export interface ScriptHandle {
  readonly pid: number;
  /** The script name that was started (diagnostics/labeling). */
  readonly scriptName: string;
  /**
   * Snapshot scrollback + current server and subscribe to subsequent events,
   * atomically (single sync op — nothing can slip between snapshot and
   * subscription). Multiple listeners may attach; each gets every later event.
   */
  readonly attach: (listener: (event: ScriptEvent) => void) => Effect.Effect<ScriptAttachment>;
  readonly isRunning: Effect.Effect<boolean>;
  /** The exit record once the child has exited (None while running). */
  readonly exit: Effect.Effect<Option.Option<ScriptExit>>;
  /** Resolves when the child exits (immediately if it already has). */
  readonly awaitExit: Effect.Effect<ScriptExit>;
}

/** A loopback TCP confirm probe: does something accept a connection on `port`? */
export type PortProber = (port: number) => Promise<boolean>;

export interface ScriptSpawnOptions {
  /** The declared script name (resolved to a command against `cwd`). */
  readonly scriptName: string;
  /** Working directory — the owning session's cwd (worktree-aware `meta.cwd`). */
  readonly cwd: string;
  /** Base environment (defaults to `process.env`); the blocklist is applied on top. */
  readonly env?: Record<string, string | undefined>;
  /** Override the command resolution (tests); defaults to the package.json lookup. */
  readonly command?: string;
  /** Override the confirm prober (tests); defaults to the loopback TCP connect. */
  readonly probePort?: PortProber;
  /** Scrollback cap in characters (tests); defaults to the wire-contract cap. */
  readonly maxScrollbackChars?: number;
}

// ---------------------------------------------------------------------------
// 2. Declared-script source (donor: the project's allowed script set)
// ---------------------------------------------------------------------------

/**
 * Read the project's `package.json` `scripts` map at `cwd` and return its
 * entries as declared scripts (bounded). A missing/unreadable/invalid
 * package.json, or one with no `scripts`, yields an empty list — never an error
 * (a non-Node project simply has nothing to run). This is the ONLY source of
 * runnable commands: the client picks a name, the server owns the command.
 */
export function listProjectScripts(cwd: string): ProjectScript[] {
  let raw: string;
  try {
    raw = readFileSync(nodePath.join(cwd, "package.json"), "utf8");
  } catch {
    return [];
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return [];
  }
  const scripts =
    typeof parsed === "object" && parsed !== null
      ? (parsed as { scripts?: unknown }).scripts
      : undefined;
  if (typeof scripts !== "object" || scripts === null) return [];
  const out: ProjectScript[] = [];
  for (const [name, command] of Object.entries(scripts as Record<string, unknown>)) {
    if (typeof command !== "string") continue;
    if (name.length === 0) continue;
    out.push({ name, command });
    if (out.length >= SCRIPT_MAX_SCRIPTS) break;
  }
  return out;
}

/**
 * Resolve a declared script name to its command string, or `null` when the name
 * is not a declared `package.json` script. The security gate: only a name that
 * appears here may run.
 */
export function resolveScriptCommand(cwd: string, scriptName: string): string | null {
  return listProjectScripts(cwd).find((script) => script.name === scriptName)?.command ?? null;
}

/** Inheritable spawn env: base minus blocklist minus undefined, with `node_modules/.bin`
 * prepended to PATH (so a declared `"dev": "vite"` resolves like `npm run` would). */
function buildScriptEnv(
  base: Record<string, string | undefined>,
  cwd: string,
): Record<string, string> {
  const env: Record<string, string> = {};
  let pathKey = "PATH";
  for (const [key, value] of Object.entries(base)) {
    if (value === undefined) continue;
    if (TERMINAL_ENV_BLOCKLIST.has(key.toUpperCase())) continue;
    if (key.toUpperCase() === "PATH") pathKey = key; // preserve original casing (Windows: Path)
    env[key] = value;
  }
  const localBin = nodePath.join(cwd, "node_modules", ".bin");
  env[pathKey] = env[pathKey] ? `${localBin}${nodePath.delimiter}${env[pathKey]}` : localBin;
  return env;
}

// ---------------------------------------------------------------------------
// 3. Port detection: loopback URL scan + loopback TCP confirm probe
// ---------------------------------------------------------------------------

/** Host tokens that resolve to the local machine — reported uniformly as `localhost`. */
const LOOPBACK_HOST_TOKENS = new Set([
  "localhost",
  "127.0.0.1",
  "0.0.0.0",
  "::1",
  "[::1]",
  "::",
  "[::]",
]);

/** `http(s)://HOST[:PORT]` — HOST is a bracketed IPv6 or a bare host/IPv4 label. */
const LOOPBACK_URL_RE = /\bhttps?:\/\/(\[[0-9a-fA-F:]+\]|[0-9a-zA-Z.-]+)(?::(\d{1,5}))?/g;

/**
 * Every DISTINCT loopback dev-server port printed in `text`, in first-seen
 * order. A non-loopback host (a LAN IP, a domain) is skipped; a URL with no
 * port is skipped (a dev server always advertises one). Exported for unit tests.
 */
export function extractLoopbackPorts(text: string): number[] {
  const ports: number[] = [];
  const seen = new Set<number>();
  LOOPBACK_URL_RE.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = LOOPBACK_URL_RE.exec(text)) !== null) {
    const host = match[1]!.toLowerCase();
    const portStr = match[2];
    if (!LOOPBACK_HOST_TOKENS.has(host)) continue;
    if (portStr === undefined) continue;
    const port = Number.parseInt(portStr, 10);
    if (!Number.isInteger(port) || port < 1 || port > 65_535) continue;
    if (seen.has(port)) continue;
    seen.add(port);
    ports.push(port);
  }
  return ports;
}

/** Build the normalized (loopback-only) server record for a confirmed port. */
function loopbackServer(port: number): DiscoveredServer {
  return { host: "localhost", port, url: `http://localhost:${port}` };
}

/** The default confirm prober: connect to `127.0.0.1:port`, bounded by a timeout. */
const defaultProbePort: PortProber = (port) =>
  new Promise<boolean>((resolve) => {
    let settled = false;
    const done = (ok: boolean): void => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolve(ok);
    };
    const socket = netConnect({ host: "127.0.0.1", port });
    socket.setTimeout(PROBE_TIMEOUT_MS);
    socket.once("connect", () => done(true));
    socket.once("timeout", () => done(false));
    socket.once("error", () => done(false));
  });

/**
 * Cap the scrollback buffer by characters, trimming the oldest output, rounded
 * to a code-point boundary (terminal.ts parity: a raw UTF-16 slice opening on a
 * low surrogate would render as U+FFFD in every future replay).
 */
function capScrollback(buffer: string, maxChars: number): string {
  if (buffer.length <= maxChars) return buffer;
  let start = buffer.length - maxChars;
  const first = buffer.charCodeAt(start);
  if (first >= 0xdc00 && first <= 0xdfff) start += 1; // lone low surrogate
  return buffer.slice(start);
}

// ---------------------------------------------------------------------------
// Default adapter: node:child_process, shell-run + cross-platform tree-kill
// ---------------------------------------------------------------------------

/** The production adapter: a shell child process with process-tree kill. */
export const nodeScriptAdapter: ScriptAdapter = {
  spawn(input) {
    const isWindows = process.platform === "win32";
    const child = nodeSpawn(input.command, {
      cwd: input.cwd,
      env: input.env,
      shell: true,
      stdio: ["ignore", "pipe", "pipe"],
      // POSIX: lead a fresh process group so kill can signal the whole tree via
      // the negative pid (Windows tree-kill goes through taskkill /T instead).
      detached: !isWindows,
    });
    if (child.pid === undefined) {
      // Synchronous spawn failure surfaces as a thrown ENOENT via the 'error'
      // event; a missing pid means the process never started.
      throw new Error(`spawn produced no pid for command: ${input.command}`);
    }
    const pid = child.pid;
    return {
      pid,
      kill: (signal) => {
        if (isWindows) {
          try {
            nodeSpawn("taskkill", ["/pid", String(pid), "/T", "/F"], { stdio: "ignore" }).on(
              "error",
              () => child.kill("SIGKILL"),
            );
          } catch {
            child.kill("SIGKILL");
          }
          return;
        }
        try {
          // Negative pid → the detached process group (see detached above).
          process.kill(-pid, signal);
        } catch {
          child.kill(signal);
        }
      },
      onData: (callback) => {
        const onChunk = (chunk: Buffer): void => callback(chunk.toString("utf8"));
        child.stdout?.on("data", onChunk);
        child.stderr?.on("data", onChunk);
        return () => {
          child.stdout?.off("data", onChunk);
          child.stderr?.off("data", onChunk);
        };
      },
      onExit: (callback) => {
        const onExit = (code: number | null, signal: NodeJS.Signals | null): void =>
          callback({ exitCode: code, signal });
        const onError = (): void => callback({ exitCode: null, signal: null });
        child.once("exit", onExit);
        child.once("error", onError);
        return () => {
          child.off("exit", onExit);
          child.off("error", onError);
        };
      },
    };
  },
};

// ---------------------------------------------------------------------------
// 4. The scoped acquire/release implementation
// ---------------------------------------------------------------------------

/**
 * Spawn one script child tied to the caller's Scope: closing the scope tree-kills
 * the child (SIGTERM → grace → SIGKILL). Fails typed with `ScriptNotDeclared`
 * when the name is not a declared script, or `ScriptSpawnFailed` when the spawn
 * throws.
 */
export const spawnScript = (
  adapter: ScriptAdapter,
  options: ScriptSpawnOptions,
): Effect.Effect<ScriptHandle, ScriptSpawnFailed | ScriptNotDeclared, Scope.Scope> =>
  Effect.map(
    Effect.acquireRelease(
      Effect.gen(function* () {
        const maxScrollbackChars = options.maxScrollbackChars ?? SCRIPT_MAX_SCROLLBACK_CHARS;
        const command = options.command ?? resolveScriptCommand(options.cwd, options.scriptName);
        if (command === null) {
          return yield* Effect.fail(new ScriptNotDeclared({ scriptName: options.scriptName }));
        }
        const env = buildScriptEnv(options.env ?? process.env, options.cwd);
        const probePort = options.probePort ?? defaultProbePort;

        const proc = yield* Effect.try({
          try: () => adapter.spawn({ command, cwd: options.cwd, env }),
          catch: (cause) => new ScriptSpawnFailed({ command, cause }),
        });

        const exitDeferred = yield* Deferred.make<ScriptExit>();

        // Closure-scoped mutable state — only touched inside single sync ops,
        // the synchronous child callbacks, or the (self-scheduled) probe
        // continuation (which re-checks these flags before dispatching).
        let scrollback = "";
        let exitState: Option.Option<ScriptExit> = Option.none();
        let server: DiscoveredServer | null = null;
        let abandoned = false;
        let portScanTail = "";
        const seenPorts = new Set<number>();
        const listeners = new Set<(event: ScriptEvent) => void>();

        const dispatch = (event: ScriptEvent): void => {
          for (const listener of listeners) listener(event);
        };

        const considerPort = (port: number): void => {
          if (seenPorts.has(port)) return;
          seenPorts.add(port);
          void probePort(port).then((listening) => {
            // The scope may have closed (abandoned) or a probe may have already
            // won the race — dispatch a server exactly once, and never after
            // the child exited (the port is gone with it).
            if (!listening || abandoned || server !== null || Option.isSome(exitState)) return;
            server = loopbackServer(port);
            dispatch({ _tag: "Server", server });
          });
        };

        const onData = proc.onData((data) => {
          scrollback = capScrollback(scrollback + data, maxScrollbackChars);
          // Detect the dev server port from THIS run's output. Prepend a short
          // tail so a URL split across two reads is still matched.
          if (server === null) {
            const combined = portScanTail + data;
            for (const port of extractLoopbackPorts(combined)) considerPort(port);
            portScanTail = combined.slice(-256);
          }
          // Split oversized reads so every dispatched chunk is wire-valid, never
          // cutting inside a surrogate pair (terminal.ts parity).
          for (let i = 0; i < data.length; ) {
            let end = Math.min(i + SCRIPT_MAX_OUTPUT_CHUNK, data.length);
            const last = data.charCodeAt(end - 1);
            if (end < data.length && last >= 0xd800 && last <= 0xdbff) end -= 1;
            dispatch({ _tag: "Output", data: data.slice(i, end) });
            i = end;
          }
        });
        const onExit = proc.onExit((exit) => {
          if (Option.isSome(exitState)) return;
          exitState = Option.some(exit);
          Deferred.unsafeDone(exitDeferred, Effect.succeed(exit));
          dispatch({ _tag: "Exit", exit });
        });

        const handle: ScriptHandle = {
          pid: proc.pid,
          scriptName: options.scriptName,
          attach: (listener) =>
            Effect.sync(() => {
              listeners.add(listener);
              return {
                scrollback,
                running: Option.isNone(exitState),
                server,
                unsubscribe: () => {
                  listeners.delete(listener);
                },
              };
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
            abandoned = true;
            onData();
            onExit();
          },
        };
      }),
      // Release: tree-kill escalation, bounded so scope close can never hang
      // (terminal.ts parity). A ScriptNotDeclared acquire produces no handle, so
      // release only runs for a live child.
      (acquired) =>
        Effect.gen(function* () {
          const { handle, proc, isExited, cleanup } = acquired;
          const killed = (signal: "SIGTERM" | "SIGKILL"): boolean => {
            try {
              proc.kill(signal);
              return true;
            } catch {
              return false;
            }
          };
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
          if (!isExited()) {
            console.error(
              `scriptRunner: pid ${proc.pid} survived SIGTERM+SIGKILL escalation — ` +
                "abandoning to keep scope close bounded (process may be leaked)",
            );
          }
          cleanup();
        }),
    ),
    (acquired) => acquired.handle,
  );

// ---------------------------------------------------------------------------
// 5. Service tag + Live layer
// ---------------------------------------------------------------------------

export interface ScriptRunnerShape {
  /** List a project's declared runnable scripts (from `package.json`). */
  readonly listScripts: (cwd: string) => Effect.Effect<ProjectScript[]>;
  /** Spawn a declared script as a resource of the caller's Scope. */
  readonly spawn: (
    options: ScriptSpawnOptions,
  ) => Effect.Effect<ScriptHandle, ScriptSpawnFailed | ScriptNotDeclared, Scope.Scope>;
}

/**
 * Factory service: runs are per-session, so the runtime-scoped service hands out
 * scoped handles rather than owning children itself (the TerminalHost/PiHost
 * pattern).
 */
export class ScriptRunner extends Context.Tag("agent-deck/server/services/ScriptRunner")<
  ScriptRunner,
  ScriptRunnerShape
>() {}

export const makeScriptRunner = (adapter: ScriptAdapter): ScriptRunnerShape => ({
  listScripts: (cwd) => Effect.sync(() => listProjectScripts(cwd)),
  spawn: (options) => spawnScript(adapter, options),
});

export const ScriptRunnerLive = Layer.succeed(ScriptRunner, makeScriptRunner(nodeScriptAdapter));
