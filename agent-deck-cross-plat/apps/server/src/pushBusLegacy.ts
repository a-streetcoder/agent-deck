import type { DomainEvent } from "@agent-deck/domain";
import type { StampedEvent } from "./services/pushBus.ts";

const DEFAULT_CAPACITY = 5_000;

/**
 * SLICE-3 EQUIVALENCE ORACLE — NOT USED AT RUNTIME.
 *
 * This is the pre-Effect `SessionPushBus` implementation, kept verbatim (class
 * renamed) solely so test/pushBus-equivalence.test.ts can drive the old and new
 * implementations with the same randomized sequence and assert identical
 * observable behavior. Delete this file with Slice 7 (transport swap), when the
 * legacy WS envelope — the last behavior this pins — goes away.
 */
export class LegacySessionPushBus {
  private seq = 0;
  private ring: StampedEvent[] = [];
  private readonly subscribers = new Set<(stamped: StampedEvent) => void>();

  constructor(private readonly capacity: number = DEFAULT_CAPACITY) {}

  get lastSeq(): number {
    return this.seq;
  }

  append(event: DomainEvent): StampedEvent {
    this.seq += 1;
    const stamped: StampedEvent = { seq: this.seq, event };
    this.ring.push(stamped);
    if (this.ring.length > this.capacity) {
      this.ring.splice(0, this.ring.length - this.capacity);
    }
    for (const subscriber of this.subscribers) {
      subscriber(stamped);
    }
    return stamped;
  }

  /**
   * Events after `lastSeq`, or null when they have already been evicted from
   * the ring (caller must fall back to a snapshot).
   */
  replayFrom(lastSeq: number): StampedEvent[] | null {
    const first = this.ring[0];
    if (lastSeq >= this.seq) return [];
    if (!first || lastSeq < first.seq - 1) return null;
    return this.ring.filter((stamped) => stamped.seq > lastSeq);
  }

  subscribe(subscriber: (stamped: StampedEvent) => void): () => void {
    this.subscribers.add(subscriber);
    return () => this.subscribers.delete(subscriber);
  }
}
