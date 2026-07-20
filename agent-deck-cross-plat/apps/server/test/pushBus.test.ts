import type { DomainEvent } from "@agent-deck/domain";
import { Effect } from "effect";
import { describe, expect, it } from "vitest";
import { SessionPushBus, type StampedEvent } from "../src/pushBus.ts";
import { makeServerRuntime } from "../src/runtime.ts";
import { SessionPushBuses } from "../src/services/pushBus.ts";

const event = (n: number): DomainEvent => ({
  type: "subagent_delta",
  cellId: `cell-${n}`,
  delta: `delta-${n}`,
});

describe("SessionPushBus (Effect-backed adapter)", () => {
  it("stamps events with a monotonic seq starting at 1", () => {
    const bus = new SessionPushBus();
    expect(bus.lastSeq).toBe(0);
    expect(bus.append(event(1)).seq).toBe(1);
    expect(bus.append(event(2)).seq).toBe(2);
    expect(bus.append(event(3)).seq).toBe(3);
    expect(bus.lastSeq).toBe(3);
  });

  it("dispatches to subscribers synchronously during append, in seq order", () => {
    const bus = new SessionPushBus();
    const seen: number[] = [];
    let sawDuringAppend = false;
    bus.subscribe(({ seq }) => {
      seen.push(seq);
      sawDuringAppend = true;
    });
    sawDuringAppend = false;
    const stamped = bus.append(event(1));
    // The subscriber must have run BEFORE append returned (sync dispatch).
    expect(sawDuringAppend).toBe(true);
    expect(seen).toEqual([stamped.seq]);
    bus.append(event(2));
    bus.append(event(3));
    expect(seen).toEqual([1, 2, 3]);
  });

  it("delivers to multiple subscribers in subscription order and honors unsubscribe", () => {
    const bus = new SessionPushBus();
    const log: string[] = [];
    const unsubA = bus.subscribe(({ seq }) => log.push(`a${seq}`));
    bus.subscribe(({ seq }) => log.push(`b${seq}`));
    bus.append(event(1));
    unsubA();
    bus.append(event(2));
    expect(log).toEqual(["a1", "b1", "b2"]);
  });

  it("replays events after lastSeq", () => {
    const bus = new SessionPushBus();
    for (let i = 1; i <= 5; i++) bus.append(event(i));
    const replay = bus.replayFrom(2);
    expect(replay?.map((s) => s.seq)).toEqual([3, 4, 5]);
    // lastSeq === 0 replays everything while nothing is evicted.
    expect(bus.replayFrom(0)?.map((s) => s.seq)).toEqual([1, 2, 3, 4, 5]);
  });

  it("returns [] when the caller is already up to date (even ahead)", () => {
    const bus = new SessionPushBus();
    expect(bus.replayFrom(0)).toEqual([]);
    expect(bus.replayFrom(7)).toEqual([]);
    bus.append(event(1));
    expect(bus.replayFrom(1)).toEqual([]);
    expect(bus.replayFrom(99)).toEqual([]);
  });

  it("evicts beyond capacity and returns null once the requested seq left the ring", () => {
    const bus = new SessionPushBus(3);
    for (let i = 1; i <= 5; i++) bus.append(event(i));
    // Ring now holds seqs 3..5.
    expect(bus.replayFrom(2)?.map((s) => s.seq)).toEqual([3, 4, 5]);
    expect(bus.replayFrom(1)).toBeNull(); // seq 2 evicted → snapshot fallback
    expect(bus.replayFrom(0)).toBeNull();
    expect(bus.replayFrom(-1)).toBeNull();
    expect(bus.replayFrom(4)?.map((s) => s.seq)).toEqual([5]);
  });

  it("preserves the stamped event payloads through replay", () => {
    const bus = new SessionPushBus();
    const e = event(42);
    const stamped = bus.append(e);
    expect(stamped.event).toBe(e);
    const replay = bus.replayFrom(0) as StampedEvent[];
    expect(replay[0]?.event).toBe(e);
  });

  // Dispatch-time semantics formerly pinned by the Slice-3 legacy-vs-Effect
  // equivalence oracle (retired in Slice 7c): a subscriber THROWING mid-dispatch,
  // and Set mutation DURING a dispatch. These are exact-behavior guarantees of
  // the synchronous single-op dispatch documented in services/pushBus.ts.
  it("a throwing subscriber: same error identity, committed state, later subscribers skipped", () => {
    const bus = new SessionPushBus(4);
    const boom = new Error("subscriber exploded");
    const after: number[] = [];
    bus.subscribe(() => {
      throw boom;
    });
    bus.subscribe(({ seq }) => after.push(seq));

    let caught: unknown;
    try {
      bus.append(event(1));
    } catch (error) {
      caught = error;
    }
    // The ORIGINAL error instance, not a wrapper (dispatch identity contract).
    expect(caught).toBe(boom);
    // State committed before dispatch: seq advanced, event replayable.
    expect(bus.lastSeq).toBe(1);
    expect(bus.replayFrom(0)).toEqual([{ seq: 1, event: event(1) }]);
    // Subscribers registered after the thrower were skipped this dispatch.
    expect(after).toEqual([]);
  });

  it("Set mutation during dispatch: mid-dispatch unsubscribe skips, mid-dispatch subscribe is visited", () => {
    const bus = new SessionPushBus(4);
    const log: string[] = [];
    // First subscriber: on the first delivery, unsubscribes the SECOND
    // subscriber (added later → not yet visited this dispatch) and registers a
    // THIRD one (which JS Set iteration visits in the same dispatch).
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
    // second skipped in dispatch 1 (unsubscribed before visited); third visited
    // in the same dispatch it was added.
    expect(log).toEqual(["first:1", "third:1", "first:2", "third:2"]);
  });
});

describe("SessionPushBuses service through the ManagedRuntime", () => {
  it("serves per-session bus handles with the same semantics", async () => {
    const runtime = makeServerRuntime();
    try {
      const result = await runtime.runPromise(
        Effect.gen(function* () {
          const buses = yield* SessionPushBuses;
          const bus = yield* buses.make(3);
          const other = yield* buses.make();

          const seen: number[] = [];
          const unsubscribe = yield* bus.subscribe(({ seq }) => seen.push(seq));
          for (let i = 1; i <= 5; i++) yield* bus.append(event(i));
          yield* unsubscribe;
          yield* bus.append(event(6));

          return {
            seen,
            lastSeq: yield* bus.lastSeq,
            replay: yield* bus.replayFrom(3),
            evicted: yield* bus.replayFrom(1),
            // `make` returns independent buses — the second one is untouched.
            otherLastSeq: yield* other.lastSeq,
          };
        }),
      );
      expect(result.seen).toEqual([1, 2, 3, 4, 5]);
      expect(result.lastSeq).toBe(6);
      expect(result.replay?.map((s) => s.seq)).toEqual([4, 5, 6]);
      expect(result.evicted).toBeNull();
      expect(result.otherLastSeq).toBe(0);
    } finally {
      await runtime.dispose();
    }
  });

  it("exposes unsafeAppend/unsafeLastSeq sync bridges with the same stamp+dispatch semantics", async () => {
    const runtime = makeServerRuntime();
    try {
      const result = await runtime.runPromise(
        Effect.gen(function* () {
          const buses = yield* SessionPushBuses;
          const bus = yield* buses.make();
          const seen: number[] = [];
          yield* bus.subscribe(({ seq }) => seen.push(seq));
          // The in-fiber SessionManager `emit` path: a synchronous append that
          // returns the stamped event directly (no runSync, no Effect wrapper).
          const first = bus.unsafeAppend(event(1));
          expect(first.seq).toBe(1);
          expect(seen).toEqual([1]); // dispatched synchronously, like append
          expect(bus.unsafeLastSeq()).toBe(1);
          // Interleaves with the Effect surface on the SAME seq counter.
          yield* bus.append(event(2));
          expect(bus.unsafeAppend(event(3)).seq).toBe(3);
          return { lastSeq: yield* bus.lastSeq, seen };
        }),
      );
      expect(result.lastSeq).toBe(3);
      expect(result.seen).toEqual([1, 2, 3]);
    } finally {
      await runtime.dispose();
    }
  });

  it("keeps stamp+dispatch atomic under concurrent fiber appends (monotonic delivery)", async () => {
    const runtime = makeServerRuntime();
    try {
      const seen = await runtime.runPromise(
        Effect.gen(function* () {
          const buses = yield* SessionPushBuses;
          const bus = yield* buses.make();
          const order: number[] = [];
          yield* bus.subscribe(({ seq }) => order.push(seq));
          // Enough concurrent appends to overflow the fiber op budget: if
          // stamping and dispatching were separate effect ops, a preemption
          // between them could deliver seq N+1 before seq N.
          yield* Effect.all(
            Array.from({ length: 500 }, (_, i) => bus.append(event(i + 1))),
            { concurrency: "unbounded" },
          );
          return order;
        }),
      );
      expect(seen).toEqual(Array.from({ length: 500 }, (_, i) => i + 1));
    } finally {
      await runtime.dispose();
    }
  });
});
