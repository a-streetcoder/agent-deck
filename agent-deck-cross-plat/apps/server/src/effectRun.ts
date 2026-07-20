import { Cause, Effect, Runtime, type ManagedRuntime } from "effect";

/**
 * The ONE unwrapping run pair shared by every synchronous class facade
 * (pushBus.ts, persistence.ts, SessionManager.ts). A defect thrown by user
 * code inside an effect (a subscriber, a predicate, an fs write) must
 * re-surface as the ORIGINAL error instance — not Effect's FiberFailure
 * wrapper — because legacy callsites stringify, `instanceof`-check, and read
 * `err.code` on what they catch. Previously copy-pasted per facade; one drift
 * in any copy would silently diverge the error-identity contract the parity
 * tests pin.
 */
export function runSyncUnwrapped<A, E>(effect: Effect.Effect<A, E>): A {
  try {
    return Effect.runSync(effect);
  } catch (error) {
    if (Runtime.isFiberFailure(error)) throw Cause.squash(error[Runtime.FiberFailureCauseId]);
    throw error;
  }
}

/** {@link runSyncUnwrapped} for a promise-returning effect, run on `runtime`. */
export async function runPromiseUnwrapped<A, E, R>(
  runtime: ManagedRuntime.ManagedRuntime<R, never>,
  effect: Effect.Effect<A, E, R>,
): Promise<A> {
  try {
    return await runtime.runPromise(effect);
  } catch (error) {
    if (Runtime.isFiberFailure(error)) throw Cause.squash(error[Runtime.FiberFailureCauseId]);
    throw error;
  }
}
