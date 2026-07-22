import type { ProjectScript } from "@agent-deck/contracts";
import { Effect, Exit, Scope } from "effect";
import { runPromiseUnwrapped, runSyncUnwrapped } from "./effectRun.ts";
import type { ServerRuntime } from "./runtime.ts";
import { ScriptRunner, type ScriptAttachment, type ScriptEvent } from "./services/scriptRunner.ts";

/**
 * The promise facade over the `ScriptRunner` Effect service (Slice 15a), for the
 * non-Effect consumer (rpcHandler.ts) — the exact role terminalGateway.ts plays
 * over TerminalHost.
 *
 * Scope ownership (the terminal convention): each started run gets a DETACHED
 * root Scope (`runtime.runSync(Scope.make())`), so the tree-killing release runs
 * when — and only when — `close()` closes that scope. The rpcHandler connection
 * is the single owner: it calls `close()` on `script_stop`, on the owning WS
 * connection dropping, and on the owning session's exit, so every teardown path
 * funnels into one scope close (no orphan dev servers).
 *
 * One running script per session: `start` rejects when the session already has a
 * live run (the client stops it first). The per-session guard is cleared when a
 * run's `close()` settles, so a stop-then-start (dev-server restart) or a
 * reconnect works.
 */

export interface OpenedScript {
  /** Server-allocated wire id (`run-N`). */
  readonly runId: string;
  /** The session this run belongs to (teardown + one-per-session bookkeeping). */
  readonly sessionId: string;
  readonly scriptName: string;
  readonly pid: number;
  /** Atomic scrollback + current-server snapshot + subscription (sync). */
  readonly attach: (listener: (event: ScriptEvent) => void) => ScriptAttachment;
  /** Close the run's scope: tree-kill the child and release everything. Idempotent. */
  readonly close: () => Promise<void>;
}

export interface ScriptRunnerGateway {
  /** List a session project's declared scripts (cwd = the session's cwd). */
  readonly listScripts: (cwd: string) => Promise<ProjectScript[]>;
  /** Start a declared script as a scope-owned run (one per session). */
  readonly start: (options: {
    sessionId: string;
    scriptName: string;
    cwd: string;
  }) => Promise<OpenedScript>;
  /**
   * Close EVERY still-open run and await the tree-kills — the server shutdown
   * step (run scopes are detached roots dispose() cannot reap, like terminals).
   */
  readonly closeAll: () => Promise<void>;
}

/** A run cannot start because one is already running for the session. */
export class ScriptAlreadyRunning extends Error {
  constructor(readonly sessionId: string) {
    super("a script is already running for this session");
    this.name = "ScriptAlreadyRunning";
  }
}

export function createScriptRunnerGateway(runtime: ServerRuntime): ScriptRunnerGateway {
  let nextRunNumber = 1;
  // Every OpenedScript whose scope may still be open — the closeAll() sweep set.
  const live = new Set<OpenedScript>();
  // One-per-session guard: the session's currently-live run, if any.
  const bySession = new Map<string, OpenedScript>();

  return {
    listScripts: (cwd) =>
      runPromiseUnwrapped(
        runtime,
        Effect.flatMap(ScriptRunner, (runner) => runner.listScripts(cwd)),
      ),
    start: async ({ sessionId, scriptName, cwd }) => {
      if (bySession.has(sessionId)) throw new ScriptAlreadyRunning(sessionId);
      const scope = runtime.runSync(Scope.make());
      let handle;
      try {
        handle = await runPromiseUnwrapped(
          runtime,
          Effect.flatMap(ScriptRunner, (runner) =>
            Scope.extend(runner.spawn({ scriptName, cwd }), scope),
          ),
        );
      } catch (error) {
        // Spawn/resolve failed: run the (empty) scope's finalizers so nothing leaks.
        await runtime.runPromise(Scope.close(scope, Exit.void)).catch(() => {});
        throw error;
      }

      const runId = `run-${nextRunNumber++}`;
      let closed: Promise<void> | null = null;

      const opened: OpenedScript = {
        runId,
        sessionId,
        scriptName: handle.scriptName,
        pid: handle.pid,
        attach: (listener) => runSyncUnwrapped(handle.attach(listener)),
        close: () => {
          closed ??= runtime.runPromise(Scope.close(scope, Exit.void)).then(() => {
            live.delete(opened);
            if (bySession.get(sessionId) === opened) bySession.delete(sessionId);
          });
          return closed;
        },
      };
      live.add(opened);
      bySession.set(sessionId, opened);

      // Release the one-per-session guard when the child exits ON ITS OWN (a dev
      // server crashing/finishing) so the user can start a fresh run without an
      // explicit stop. The run stays reattachable (scrollback + the exit event)
      // until `close()`; only the guard is released. If it already exited during
      // the spawn round-trip, release immediately.
      const releaseGuardOnExit = (): void => {
        if (bySession.get(sessionId) === opened) bySession.delete(sessionId);
      };
      const guardAttach = runSyncUnwrapped(
        handle.attach((event) => {
          if (event._tag === "Exit") releaseGuardOnExit();
        }),
      );
      if (!guardAttach.running) {
        guardAttach.unsubscribe();
        releaseGuardOnExit();
      }
      return opened;
    },
    closeAll: async () => {
      await Promise.all([...live].map((run) => run.close().catch(() => {})));
    },
  };
}
