import { Effect, Exit, Scope } from "effect";
import { runPromiseUnwrapped, runSyncUnwrapped } from "./effectRun.ts";
import type { ServerRuntime } from "./runtime.ts";
import {
  TerminalHost,
  type TerminalAttachment,
  type TerminalEvent,
  type TerminalSpawnOptions,
} from "./services/terminal.ts";

/**
 * The synchronous/promise facade over the `TerminalHost` Effect service
 * (Slice 8a), for the non-Effect consumer (rpcHandler.ts) — the exact role
 * `SessionManager` plays over `SessionManagerService`.
 *
 * Scope ownership (the SessionManager convention): each opened terminal gets a
 * DETACHED root Scope (`runtime.runSync(Scope.make())`), so the PTY-killing
 * release runs when — and only when — `close()` closes that scope. The
 * rpcHandler connection is the single owner: it calls `close()` on
 * `terminal_close`, on the owning WS connection dropping, and on the owning
 * session's exit, so every teardown path funnels into one scope close.
 */

export interface OpenedTerminal {
  /** Server-allocated wire id (`term-N`). */
  readonly terminalId: string;
  /** The session this terminal belongs to (teardown bookkeeping). */
  readonly sessionId: string;
  readonly pid: number;
  readonly write: (data: string) => Promise<void>;
  readonly resize: (cols: number, rows: number) => Promise<void>;
  /** Atomic scrollback snapshot + subscription (sync — see services/terminal.ts). */
  readonly attach: (listener: (event: TerminalEvent) => void) => TerminalAttachment;
  /** Pause the PTY's output flow (socket backpressure). Safe after exit. */
  readonly pause: () => void;
  /** Resume the PTY's output flow after a pause. Safe after exit. */
  readonly resume: () => void;
  /** Close the terminal's scope: kill the PTY and release everything. Idempotent. */
  readonly close: () => Promise<void>;
}

export interface TerminalGateway {
  /** Spawn a new scope-owned terminal for a session (cwd = the session's cwd). */
  readonly open: (options: { sessionId: string } & TerminalSpawnOptions) => Promise<OpenedTerminal>;
  /**
   * Close EVERY still-open terminal and await the PTY kills — the server
   * shutdown step. Terminal scopes are detached roots (like session scopes),
   * so `effectRuntime.dispose()` cannot reap them, and the per-connection
   * socket-close teardown is fire-and-forget; this is the deterministic,
   * awaitable sweep `close()` runs before disposing the runtime.
   */
  readonly closeAll: () => Promise<void>;
}

export function createTerminalGateway(runtime: ServerRuntime): TerminalGateway {
  let nextTerminalNumber = 1;
  // Every OpenedTerminal whose scope may still be open (removed once its
  // close settles) — the closeAll() sweep set.
  const live = new Set<OpenedTerminal>();

  return {
    open: async ({ sessionId, ...spawnOptions }) => {
      const scope = runtime.runSync(Scope.make());
      let handle;
      try {
        handle = await runPromiseUnwrapped(
          runtime,
          Effect.flatMap(TerminalHost, (host) => Scope.extend(host.spawn(spawnOptions), scope)),
        );
      } catch (error) {
        // Spawn failed: run the (empty) scope's finalizers so nothing leaks.
        await runtime.runPromise(Scope.close(scope, Exit.void)).catch(() => {});
        throw error;
      }

      const terminalId = `term-${nextTerminalNumber++}`;
      let closed: Promise<void> | null = null;

      const opened: OpenedTerminal = {
        terminalId,
        sessionId,
        pid: handle.pid,
        write: (data) => runPromiseUnwrapped(runtime, handle.write(data)),
        resize: (cols, rows) => runPromiseUnwrapped(runtime, handle.resize(cols, rows)),
        attach: (listener) => runSyncUnwrapped(handle.attach(listener)),
        pause: () => runSyncUnwrapped(handle.pause),
        resume: () => runSyncUnwrapped(handle.resume),
        close: () => {
          closed ??= runtime.runPromise(Scope.close(scope, Exit.void)).then(() => {
            live.delete(opened);
          });
          return closed;
        },
      };
      live.add(opened);
      return opened;
    },
    closeAll: async () => {
      // close() is idempotent/memoized, so racing the per-connection teardown
      // is safe — both paths await the same scope-close promise.
      await Promise.all([...live].map((terminal) => terminal.close().catch(() => {})));
    },
  };
}
