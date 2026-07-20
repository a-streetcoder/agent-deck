import type { DomainEvent } from "@agent-deck/domain";
import { Effect } from "effect";
import { runSyncUnwrapped } from "./effectRun.ts";
import {
  DEFAULT_PUSH_BUS_CAPACITY,
  makeSessionPushBusHandle,
  type SessionPushBusHandle,
  type StampedEvent,
} from "./services/pushBus.ts";

export type { StampedEvent };

/**
 * Thin synchronous adapter over the Effect push-bus service (Slice 3): same
 * class API as before the migration, so SessionManager/wsHandler callsites
 * don't churn until they become Effect-native (Slice 5 / Slice 7).
 *
 * All methods delegate to a `SessionPushBusHandle` — the exact implementation
 * `SessionPushBuses` (services/pushBus.ts) serves through the ManagedRuntime.
 * The handle is deliberately context-free and fully synchronous inside, so
 * `Effect.runSync` here is total: subscribers are still dispatched
 * synchronously during `append()`, in seq order (see the sync-vs-async note in
 * services/pushBus.ts). Subscriber exceptions keep their legacy identity via
 * `runSyncUnwrapped`.
 */
export class SessionPushBus {
  private readonly handle: SessionPushBusHandle;

  constructor(capacity: number = DEFAULT_PUSH_BUS_CAPACITY) {
    this.handle = Effect.runSync(makeSessionPushBusHandle(capacity));
  }

  get lastSeq(): number {
    return Effect.runSync(this.handle.lastSeq);
  }

  append(event: DomainEvent): StampedEvent {
    return runSyncUnwrapped(this.handle.append(event));
  }

  /**
   * Events after `lastSeq`, or null when they have already been evicted from
   * the ring (caller must fall back to a snapshot).
   */
  replayFrom(lastSeq: number): StampedEvent[] | null {
    return Effect.runSync(this.handle.replayFrom(lastSeq));
  }

  subscribe(subscriber: (stamped: StampedEvent) => void): () => void {
    const unsubscribe = Effect.runSync(this.handle.subscribe(subscriber));
    return () => Effect.runSync(unsubscribe);
  }
}
