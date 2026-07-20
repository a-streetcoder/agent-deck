import { describe, expect, it } from "vitest";
import { Schema } from "effect";
import { RpcServerFrame } from "@agent-deck/contracts";
import {
  RpcTransport,
  type ConnectionState,
  type TimerHandle,
  type WebSocketLike,
} from "../src/transport.ts";

/**
 * A fake WebSocket + a manual reconnect clock, so the state machine is exercised
 * with zero I/O and fully deterministic timing.
 */
class FakeSocket implements WebSocketLike {
  onopen: (() => void) | null = null;
  onmessage: ((event: { data: unknown }) => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  readonly sent: string[] = [];
  closed = false;

  constructor(readonly url: string) {}

  send(data: string): void {
    this.sent.push(data);
  }
  close(): void {
    this.closed = true;
  }

  // --- test drivers ---
  open(): void {
    this.onopen?.();
  }
  message(data: unknown): void {
    this.onmessage?.({ data: typeof data === "string" ? data : JSON.stringify(data) });
  }
  drop(): void {
    this.onclose?.();
  }
}

interface ScheduledTimer {
  fn: () => void;
  ms: number;
  handle: number;
}

class FakeClock {
  private timers: ScheduledTimer[] = [];
  private nextHandle = 1;
  readonly delays: number[] = [];

  setTimer = (fn: () => void, ms: number): TimerHandle => {
    const handle = this.nextHandle++;
    this.timers.push({ fn, ms, handle });
    this.delays.push(ms);
    return handle as unknown as TimerHandle;
  };
  clearTimer = (handle: TimerHandle): void => {
    this.timers = this.timers.filter((t) => t.handle !== (handle as unknown as number));
  };
  /** Fire (and remove) all currently-scheduled timers. */
  flush(): void {
    const due = this.timers;
    this.timers = [];
    for (const t of due) t.fn();
  }
  get pending(): number {
    return this.timers.length;
  }
}

function makeHarness(overrides?: {
  backoff?: { initialMs: number; maxMs: number; factor: number };
}) {
  const sockets: FakeSocket[] = [];
  const states: ConnectionState[] = [];
  const pushes: unknown[] = [];
  const decodeErrors: string[] = [];
  let connectedCount = 0;
  const clock = new FakeClock();

  const transport = new RpcTransport({
    url: "ws://localhost/rpc",
    webSocketCtor: class extends FakeSocket {
      constructor(url: string) {
        super(url);
        sockets.push(this);
      }
    },
    onState: (s) => states.push(s),
    onConnected: () => connectedCount++,
    onPush: (m) => pushes.push(m),
    onDecodeError: (e) => decodeErrors.push(e),
    backoff: overrides?.backoff ?? { initialMs: 500, maxMs: 10_000, factor: 2 },
    setTimer: clock.setTimer,
    clearTimer: clock.clearTimer,
  });

  return {
    transport,
    sockets,
    states,
    pushes,
    decodeErrors,
    clock,
    connectedCount: () => connectedCount,
  };
}

const pushFrame = (message: unknown) => JSON.stringify({ kind: "push", message });

describe("RpcTransport state machine", () => {
  it("connect → connecting → connected fires onConnected", () => {
    const h = makeHarness();
    h.transport.connect();
    expect(h.transport.getState()).toBe("connecting");
    expect(h.sockets).toHaveLength(1);

    h.sockets[0]!.open();
    expect(h.transport.getState()).toBe("connected");
    expect(h.connectedCount()).toBe(1);
    expect(h.states).toEqual(["connecting", "connected"]);
  });

  it("decodes a valid push through the contract and forwards it", () => {
    const h = makeHarness();
    h.transport.connect();
    h.sockets[0]!.open();

    const event = { type: "event", sessionId: "s1", seq: 3, event: { kind: "text_delta" } };
    // sanity: the frame is contract-valid
    expect(Schema.decodeUnknownEither(RpcServerFrame)({ kind: "push", message: event })._tag).toBe(
      "Right",
    );

    h.sockets[0]!.message(pushFrame(event));
    expect(h.pushes).toHaveLength(1);
    expect(h.pushes[0]).toMatchObject({ type: "event", sessionId: "s1", seq: 3 });
    expect(h.decodeErrors).toHaveLength(0);
  });

  it("rejects a malformed push at the boundary (onDecodeError, not onPush)", () => {
    const h = makeHarness();
    h.transport.connect();
    h.sockets[0]!.open();

    // missing seq + sessionId → fails ServerMessage `event` decode
    h.sockets[0]!.message(pushFrame({ type: "event" }));
    // entirely unknown frame kind
    h.sockets[0]!.message(JSON.stringify({ kind: "nonsense" }));
    // not even JSON
    h.sockets[0]!.message("}{ broken");

    expect(h.pushes).toHaveLength(0);
    expect(h.decodeErrors).toHaveLength(3);
  });

  it("correlates replies: ack resolves, failure rejects", async () => {
    const h = makeHarness();
    h.transport.connect();
    h.sockets[0]!.open();

    const okPromise = h.transport.request({ type: "abort", sessionId: "s1" });
    const errPromise = h.transport.request({ type: "abort", sessionId: "s2" });

    // Two frames were sent with ids 1 and 2.
    expect(h.sockets[0]!.sent).toHaveLength(2);
    const ids = h.sockets[0]!.sent.map((s) => (JSON.parse(s) as { id: number }).id);
    expect(ids).toEqual([1, 2]);

    h.sockets[0]!.message(JSON.stringify({ kind: "reply", id: ids[0], ok: true }));
    h.sockets[0]!.message(
      JSON.stringify({ kind: "reply", id: ids[1], ok: false, error: "unknown session" }),
    );

    await expect(okPromise).resolves.toEqual([]);
    await expect(errPromise).rejects.toThrow("unknown session");
  });

  it("hello resolves with the session list", async () => {
    const h = makeHarness();
    h.transport.connect();
    h.sockets[0]!.open();

    const promise = h.transport.hello();
    const id = (JSON.parse(h.sockets[0]!.sent[0]!) as { id: number }).id;
    const sessions = [{ id: "s1", cwd: "/tmp", createdAt: "2026-01-01T00:00:00.000Z" }];
    h.sockets[0]!.message(JSON.stringify({ kind: "hello_ok", id, sessions }));

    await expect(promise).resolves.toEqual(sessions);
  });

  it("request while disconnected rejects immediately", async () => {
    const h = makeHarness();
    await expect(h.transport.request({ type: "abort", sessionId: "s1" })).rejects.toThrow(
      "not connected",
    );
  });

  it("reconnects on unexpected drop with exponential backoff, capped, reset on open", () => {
    const h = makeHarness({ backoff: { initialMs: 500, maxMs: 2_000, factor: 2 } });
    h.transport.connect();
    h.sockets[0]!.open();
    expect(h.transport.getState()).toBe("connected");

    // 1st drop → reconnecting, schedules 500ms
    h.sockets[0]!.drop();
    expect(h.transport.getState()).toBe("reconnecting");
    expect(h.clock.delays).toEqual([500]);

    // timer fires → new socket, connecting
    h.clock.flush();
    expect(h.sockets).toHaveLength(2);
    expect(h.transport.getState()).toBe("connecting");

    // 2nd drop (never opened) → 1000ms
    h.sockets[1]!.drop();
    expect(h.clock.delays).toEqual([500, 1000]);
    h.clock.flush();

    // 3rd drop → 2000ms (cap)
    h.sockets[2]!.drop();
    expect(h.clock.delays).toEqual([500, 1000, 2000]);
    h.clock.flush();

    // 4th drop → still capped at 2000ms
    h.sockets[3]!.drop();
    expect(h.clock.delays).toEqual([500, 1000, 2000, 2000]);
    h.clock.flush();

    // a successful open resets the backoff to initial
    h.sockets[4]!.open();
    expect(h.transport.getState()).toBe("connected");
    h.sockets[4]!.drop();
    expect(h.clock.delays.at(-1)).toBe(500);
  });

  it("connect() during backoff supersedes the pending retry (no duplicate socket)", () => {
    const h = makeHarness();
    h.transport.connect();
    h.sockets[0]!.open();
    // Unexpected drop → reconnecting, retry timer armed.
    h.sockets[0]!.drop();
    expect(h.transport.getState()).toBe("reconnecting");
    expect(h.clock.pending).toBe(1);

    // Caller-driven reconnect during the backoff window must CLEAR the armed
    // timer: without that, the stale timer fires after this connect() and
    // opens a second socket — orphaning ours live with a duplicate
    // server-side subscription.
    h.transport.connect();
    expect(h.sockets).toHaveLength(2);
    expect(h.clock.pending).toBe(0);

    // Even flushing the clock opens nothing further.
    h.clock.flush();
    expect(h.sockets).toHaveLength(2);
    h.sockets[1]!.open();
    expect(h.transport.getState()).toBe("connected");
  });

  it("close() stops reconnect and rejects pending", async () => {
    const h = makeHarness();
    h.transport.connect();
    h.sockets[0]!.open();

    const pending = h.transport.request({ type: "abort", sessionId: "s1" });
    h.transport.close();

    expect(h.transport.getState()).toBe("closed");
    expect(h.sockets[0]!.closed).toBe(true);
    await expect(pending).rejects.toThrow("transport closed");

    // A drop from the (now-orphaned) socket must NOT schedule a reconnect.
    h.sockets[0]!.drop();
    expect(h.clock.pending).toBe(0);
    expect(h.transport.getState()).toBe("closed");
  });

  it("a drop with pending requests rejects them before reconnecting", async () => {
    const h = makeHarness();
    h.transport.connect();
    h.sockets[0]!.open();

    const pending = h.transport.request({ type: "compact", sessionId: "s1" });
    h.sockets[0]!.drop();
    await expect(pending).rejects.toThrow("disconnected");
    expect(h.transport.getState()).toBe("reconnecting");
  });
});
