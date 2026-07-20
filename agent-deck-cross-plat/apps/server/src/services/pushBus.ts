import type { DomainEvent } from "@agent-deck/domain";
import { Chunk, Context, Effect, Layer, Option } from "effect";

/**
 * SessionPushBus as an Effect service (Slice 3 — the first Effect service in
 * the runtime path; later slices copy this file's shape).
 *
 * File anatomy (the template):
 *   1. data types + handle interface (effectful API surface)
 *   2. `make*` effect(s) building the implementation
 *   3. `Context.Tag` service class (t3code's Services/ role)
 *   4. `*Live` Layer (t3code's Layers/ role) — joined into `serverLayers`
 *      in ../runtime.ts
 *
 * ## Sync-vs-async dispatch: DELIBERATELY SYNCHRONOUS
 *
 * The legacy class dispatched to subscribers synchronously *during* `append()`,
 * and callsites rely on that observable ordering: SessionManager ingests pi
 * events synchronously so stamping happens in pi-stdout order, and wsHandler's
 * subscriber pushes straight to the WebSocket — events reach the socket in seq
 * order with no interleaving. Effect `PubSub` is asynchronous (publishers and
 * subscribers meet through queues serviced by fibers), which would break that
 * guarantee — or at least demand a proof that it holds. So this service does
 * NOT use PubSub: seq + ring + subscribers are closure-scoped state, and every
 * handle operation is a SINGLE `Effect.sync` op. That single-op shape is
 * load-bearing twice over:
 *
 *   - Under `runSync` — as the `SessionPushBus` class adapter in ../pushBus.ts
 *     does — every subscriber has observed the stamped event before `append`
 *     returns, exactly like the legacy class.
 *   - Under fiber execution (`runPromise`/`runFork` through the
 *     ManagedRuntime) a fiber can only yield BETWEEN effect ops, never inside
 *     one, so append's stamp+dispatch is atomic: two concurrent appends can
 *     never deliver seq N+1 before seq N. (An earlier draft used `Ref.modify`
 *     for the stamp and a separate `Effect.tap` for the dispatch; that two-op
 *     shape left a preemption window between stamping and dispatching, which
 *     would have broken monotonic delivery once an Effect-native consumer —
 *     Slice 5's SessionManager — ran `append` in a fiber.)
 *
 * Revisit only at Slice 7 (transport swap), where the WS boundary is rebuilt
 * and an async hand-off could be proven end-to-end.
 *
 * Subscribers are intentionally held in a closure-scoped mutable `Set` (only
 * ever touched inside `Effect.sync`), not a `Ref<ReadonlySet>`: the dispatch
 * loop iterates the live Set just like the legacy implementation, so
 * subscribe/unsubscribe *during* a dispatch keeps the exact legacy semantics
 * (JS Set iteration skips entries removed mid-loop and visits ones added).
 *
 * ## Template caveats for Effect-NATIVE consumers (Slice 5 / Slice 7)
 *
 * Two surfaces here are legacy-parity compromises, not idioms to copy:
 *   - `subscribe` returns a nested-effect unsubscribe handle so the sync class
 *     adapter can runSync it. The Effect-native surface, when the first fiber
 *     consumer lands, should be a `subscribeScoped` variant
 *     (`Effect<void, never, Scope>` via `Effect.acquireRelease`) tying the
 *     subscription to the consumer's Scope.
 *   - `replayFrom` keeps the legacy null sentinel (null = evicted → snapshot).
 *     Effect-native consumers should get an `Option<StampedEvent[]>` surface,
 *     with the adapter mapping back via `Option.getOrNull`.
 */

export interface StampedEvent {
  seq: number;
  event: DomainEvent;
}

export type PushSubscriber = (stamped: StampedEvent) => void;

export const DEFAULT_PUSH_BUS_CAPACITY = 5_000;

/**
 * One session's ordered event log: every domain event gets a monotonic seq
 * before fan-out, and a ring buffer lets reconnecting clients replay from
 * their last seen seq instead of re-snapshotting.
 */
export interface SessionPushBusHandle {
  /** Highest seq stamped so far (0 before the first append). */
  readonly lastSeq: Effect.Effect<number>;
  /** Stamp, ring-buffer, and synchronously fan out one event. */
  readonly append: (event: DomainEvent) => Effect.Effect<StampedEvent>;
  /**
   * Events after `lastSeq`, or null when they have already been evicted from
   * the ring (caller must fall back to a snapshot).
   */
  readonly replayFrom: (lastSeq: number) => Effect.Effect<StampedEvent[] | null>;
  /** Register a subscriber; the yielded effect unregisters it. */
  readonly subscribe: (subscriber: PushSubscriber) => Effect.Effect<Effect.Effect<void>>;

  /**
   * Synchronous stamp+dispatch for in-fiber service logic (Slice 5's
   * SessionManager `emit`): does exactly what {@link append} does, but returns
   * the stamped event directly instead of wrapping it in an `Effect`, so a
   * synchronous domain-event callback can push into the bus WITHOUT capturing a
   * runtime via `runSync` (the pushBus caveat, mirrored by piHost's
   * `Queue.unsafeOffer` bridge). Same single-op atomicity as `append` — the
   * whole stamp+dispatch runs synchronously with no suspension point.
   */
  readonly unsafeAppend: (event: DomainEvent) => StampedEvent;
  /** Synchronous read of {@link lastSeq} for the same in-fiber callers. */
  readonly unsafeLastSeq: () => number;
}

interface RingState {
  seq: number;
  ring: Chunk.Chunk<StampedEvent>;
}

/** Build one bus handle. Context-free: needs no services, only fresh state. */
export const makeSessionPushBusHandle = (
  capacity: number = DEFAULT_PUSH_BUS_CAPACITY,
): Effect.Effect<SessionPushBusHandle> =>
  Effect.sync(() => {
    // Closure-scoped mutable state, only ever touched inside a single
    // `Effect.sync` op — see the atomicity note in the module doc.
    let state: RingState = { seq: 0, ring: Chunk.empty() };
    const subscribers = new Set<PushSubscriber>();

    // Stamp AND dispatch in one synchronous unit: no fiber can be preempted
    // between seq N being committed and subscribers observing it, so delivery
    // stays monotonic even when appends run concurrently in fibers. This is the
    // shared core behind both `append` (the Effect surface) and `unsafeAppend`
    // (the sync bridge for in-fiber callers).
    const appendSync = (event: DomainEvent): StampedEvent => {
      const seq = state.seq + 1;
      const stamped: StampedEvent = { seq, event };
      let ring: Chunk.Chunk<StampedEvent> = Chunk.append(state.ring, stamped);
      const overflow = Chunk.size(ring) - capacity;
      if (overflow > 0) ring = Chunk.drop(ring, overflow);
      state = { seq, ring };
      // INVARIANT: subscribers must NOT (transitively) call back into this
      // bus. A re-entrant append would run to completion mid-loop — delivering
      // seq N+1 to every subscriber before the remaining subscribers here have
      // seen seq N — breaking monotonic delivery. No production subscriber
      // does this (wsHandler pushes to a socket; sessionManager's synthetic
      // emitters run on separate call stacks); keep it that way. A throwing
      // subscriber also starves the ones after it in the Set (legacy parity —
      // pinned by the thrower-first test in pushBus.test.ts).
      for (const subscriber of subscribers) subscriber(stamped);
      return stamped;
    };

    const append = (event: DomainEvent): Effect.Effect<StampedEvent> =>
      Effect.sync(() => appendSync(event));

    const replayFrom = (lastSeq: number): Effect.Effect<StampedEvent[] | null> =>
      Effect.sync(() => {
        const { seq, ring } = state;
        if (lastSeq >= seq) return [];
        const first = Chunk.head(ring);
        if (Option.isNone(first) || lastSeq < first.value.seq - 1) return null;
        return Chunk.toArray(Chunk.filter(ring, (stamped) => stamped.seq > lastSeq));
      });

    const subscribe = (subscriber: PushSubscriber): Effect.Effect<Effect.Effect<void>> =>
      Effect.sync(() => {
        subscribers.add(subscriber);
        return Effect.sync(() => {
          subscribers.delete(subscriber);
        });
      });

    return {
      lastSeq: Effect.sync(() => state.seq),
      append,
      replayFrom,
      subscribe,
      unsafeAppend: appendSync,
      unsafeLastSeq: () => state.seq,
    } satisfies SessionPushBusHandle;
  });

export interface SessionPushBusesShape {
  /** Create a fresh per-session bus (one per ManagedSession). */
  readonly make: (capacity?: number) => Effect.Effect<SessionPushBusHandle>;
}

/**
 * Factory service: buses are per-session, so the runtime-scoped service hands
 * out fresh handles rather than being one global bus.
 */
export class SessionPushBuses extends Context.Tag("agent-deck/server/services/SessionPushBuses")<
  SessionPushBuses,
  SessionPushBusesShape
>() {}

export const SessionPushBusesLive = Layer.succeed(SessionPushBuses, {
  make: makeSessionPushBusHandle,
});
