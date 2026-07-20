import type { DomainEvent } from "@agent-deck/domain";
import { describe, expect, it } from "vitest";
import { SessionPushBus } from "../src/pushBus.ts";
import { LegacySessionPushBus } from "../src/pushBusLegacy.ts";

/**
 * Replay-equivalence oracle test (Slice 3): drives the legacy pre-Effect
 * SessionPushBus and the Effect-backed one with the SAME seeded pseudo-random
 * sequence of appends, replays (including negative / ancient / future seqs),
 * subscribes and unsubscribes — with a small capacity so ring eviction is
 * constantly exercised — and asserts identical observable behavior at every
 * step: stamped seqs, lastSeq, replay results (incl. eviction nulls), and
 * per-subscriber delivery order. Dies with Slice 7 alongside pushBusLegacy.ts.
 */

/** mulberry32 — tiny deterministic PRNG, good enough for op sequencing. */
function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

interface BusLike {
  readonly lastSeq: number;
  append(event: DomainEvent): { seq: number; event: DomainEvent };
  replayFrom(lastSeq: number): Array<{ seq: number; event: DomainEvent }> | null;
  subscribe(subscriber: (stamped: { seq: number; event: DomainEvent }) => void): () => void;
}

interface Harness {
  bus: BusLike;
  /** Flat log of every subscriber delivery: "subscriberId:seq". */
  deliveries: string[];
  unsubscribers: Map<number, () => void>;
}

function makeHarness(bus: BusLike): Harness {
  return { bus, deliveries: [], unsubscribers: new Map() };
}

function runScenario(seed: number, opCount: number, capacity: number): void {
  const rand = mulberry32(seed);
  const legacy = makeHarness(new LegacySessionPushBus(capacity));
  const effectful = makeHarness(new SessionPushBus(capacity));
  let nextSubscriberId = 0;
  let eventCounter = 0;

  for (let op = 0; op < opCount; op++) {
    const roll = rand();
    const at = `seed=${seed} op=${op}`;

    if (roll < 0.55) {
      // append — identical payload object shape for both.
      eventCounter += 1;
      const make = (): DomainEvent => ({
        type: "subagent_delta",
        cellId: `cell-${eventCounter}`,
        delta: `d${eventCounter}`,
      });
      const a = legacy.bus.append(make());
      const b = effectful.bus.append(make());
      expect(b.seq, at).toBe(a.seq);
      expect(b.event, at).toEqual(a.event);
    } else if (roll < 0.8) {
      // replayFrom with a lastSeq spanning ancient/evicted/current/future.
      const span = legacy.bus.lastSeq + 4;
      const lastSeq = Math.floor(rand() * span) - 2;
      const a = legacy.bus.replayFrom(lastSeq);
      const b = effectful.bus.replayFrom(lastSeq);
      expect(b, `${at} replayFrom(${lastSeq})`).toEqual(a);
    } else if (roll < 0.92) {
      // subscribe a paired logging subscriber to both buses.
      const id = nextSubscriberId++;
      const unsubA = legacy.bus.subscribe(({ seq }) => legacy.deliveries.push(`${id}:${seq}`));
      const unsubB = effectful.bus.subscribe(({ seq }) =>
        effectful.deliveries.push(`${id}:${seq}`),
      );
      legacy.unsubscribers.set(id, unsubA);
      effectful.unsubscribers.set(id, unsubB);
    } else {
      // unsubscribe a random active subscriber from both.
      const active = [...legacy.unsubscribers.keys()];
      if (active.length > 0) {
        const id = active[Math.floor(rand() * active.length)]!;
        legacy.unsubscribers.get(id)!();
        effectful.unsubscribers.get(id)!();
        legacy.unsubscribers.delete(id);
        effectful.unsubscribers.delete(id);
      }
    }

    expect(effectful.bus.lastSeq, at).toBe(legacy.bus.lastSeq);
  }

  // Delivery logs must match exactly: same subscribers saw the same seqs in
  // the same total order.
  expect(effectful.deliveries).toEqual(legacy.deliveries);

  // Exhaustive final replay sweep across the whole seq range (plus margins):
  // identical arrays where the ring still covers lastSeq, identical eviction
  // nulls where it doesn't.
  for (let lastSeq = -2; lastSeq <= legacy.bus.lastSeq + 2; lastSeq++) {
    const a = legacy.bus.replayFrom(lastSeq);
    const b = effectful.bus.replayFrom(lastSeq);
    expect(b, `final replayFrom(${lastSeq}) seed=${seed}`).toEqual(a);
  }
}

describe("legacy vs Effect push bus equivalence (seeded randomized)", () => {
  const seeds = [1, 2, 3, 42, 1337, 20260720];

  it.each(seeds)("seed %i — small ring (capacity 8, heavy eviction)", (seed) => {
    runScenario(seed, 600, 8);
  });

  it.each(seeds)("seed %i — capacity 1 (degenerate ring)", (seed) => {
    runScenario(seed + 1000, 300, 1);
  });

  it("matches on an untouched bus and across the empty-ring edge", () => {
    const legacy = new LegacySessionPushBus(4);
    const effectful = new SessionPushBus(4);
    for (const lastSeq of [-1, 0, 1, 5]) {
      expect(effectful.replayFrom(lastSeq)).toEqual(legacy.replayFrom(lastSeq));
    }
    expect(effectful.lastSeq).toBe(legacy.lastSeq);
  });

  // Pins the dispatch semantics the randomized driver never reaches: a
  // subscriber THROWING mid-dispatch, and Set mutation DURING a dispatch —
  // both claimed as exact-legacy guarantees in services/pushBus.ts.
  it("a throwing subscriber: same error identity, committed state, later subscribers skipped", () => {
    const event: DomainEvent = { type: "subagent_delta", cellId: "c", delta: "d" };
    for (const bus of [new LegacySessionPushBus(4), new SessionPushBus(4)]) {
      const boom = new Error("subscriber exploded");
      const after: number[] = [];
      bus.subscribe(() => {
        throw boom;
      });
      bus.subscribe(({ seq }) => after.push(seq));

      let caught: unknown;
      try {
        bus.append(event);
      } catch (error) {
        caught = error;
      }
      // The ORIGINAL error instance, not a wrapper (legacy identity contract).
      expect(caught).toBe(boom);
      // State committed before dispatch: seq advanced, event replayable.
      expect(bus.lastSeq).toBe(1);
      expect(bus.replayFrom(0)).toEqual([{ seq: 1, event }]);
      // Subscribers registered after the thrower were skipped.
      expect(after).toEqual([]);
    }
  });

  it("Set mutation during dispatch: mid-dispatch unsubscribe skips, mid-dispatch subscribe is visited", () => {
    const event = (n: number): DomainEvent => ({
      type: "subagent_delta",
      cellId: `c${n}`,
      delta: `d${n}`,
    });
    const run = (bus: LegacySessionPushBus | SessionPushBus): string[] => {
      const log: string[] = [];
      // First subscriber: on the first delivery, unsubscribes the SECOND
      // subscriber (added later → not yet visited this dispatch) and registers
      // a THIRD one (which JS Set iteration visits in the same dispatch).
      const second: { unsub?: () => void } = {};
      let mutated = false;
      bus.subscribe(({ seq }) => {
        log.push(`first:${seq}`);
        if (!mutated) {
          mutated = true;
          second.unsub?.();
          bus.subscribe(({ seq: s }) => log.push(`third:${s}`));
        }
      });
      second.unsub = bus.subscribe(({ seq }) => log.push(`second:${seq}`));
      bus.append(event(1));
      bus.append(event(2));
      return log;
    };
    const legacyLog = run(new LegacySessionPushBus(4));
    const effectLog = run(new SessionPushBus(4));
    expect(effectLog).toEqual(legacyLog);
    // And the shape itself: second skipped in dispatch 1, third visited in it.
    expect(legacyLog).toEqual(["first:1", "third:1", "first:2", "third:2"]);
  });
});
