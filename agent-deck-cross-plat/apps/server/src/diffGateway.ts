import { Effect } from "effect";
import { runPromiseUnwrapped } from "./effectRun.ts";
import type { ServerRuntime } from "./runtime.ts";
import {
  SessionDiff,
  type DiffFileSet,
  type DiffRefreshResult,
  type FileDiffResult,
} from "./services/diff.ts";

/**
 * The promise facade over the `SessionDiff` Effect service (Slice 9), for the
 * non-Effect consumers (rpcHandler.ts ops, server.ts's turn-boundary hook) —
 * the exact role terminalGateway.ts plays over TerminalHost. No scopes here:
 * diff computations are one-shot effects, so the facade is a thin
 * runPromise/runSync bridge onto the runtime's service.
 */

export interface DiffGateway {
  /** The session's changed-file set (cached; computes on first call). */
  readonly listFiles: (sessionId: string, cwd: string) => Promise<DiffFileSet>;
  /** Recompute now (turn boundary / on demand); reports whether the set changed. */
  readonly refresh: (sessionId: string, cwd: string) => Promise<DiffRefreshResult>;
  /** One file's bounded unified diff (empty for unknown paths / binary files). */
  readonly fileDiff: (sessionId: string, cwd: string, path: string) => Promise<FileDiffResult>;
  /** Drop the session's cache entry (session ended/destroyed). */
  readonly drop: (sessionId: string) => void;
}

export function createDiffGateway(runtime: ServerRuntime): DiffGateway {
  return {
    listFiles: (sessionId, cwd) =>
      runPromiseUnwrapped(
        runtime,
        Effect.flatMap(SessionDiff, (diff) => diff.listFiles(sessionId, cwd)),
      ),
    refresh: (sessionId, cwd) =>
      runPromiseUnwrapped(
        runtime,
        Effect.flatMap(SessionDiff, (diff) => diff.refresh(sessionId, cwd)),
      ),
    fileDiff: (sessionId, cwd, path) =>
      runPromiseUnwrapped(
        runtime,
        Effect.flatMap(SessionDiff, (diff) => diff.fileDiff(sessionId, cwd, path)),
      ),
    drop: (sessionId) =>
      runtime.runSync(Effect.flatMap(SessionDiff, (diff) => diff.drop(sessionId))),
  };
}
