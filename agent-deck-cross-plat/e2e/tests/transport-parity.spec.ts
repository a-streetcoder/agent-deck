import { expect, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Reconnect / replay PARITY on the new Effect-RPC `/rpc` transport (Slice 7b).
 *
 * These drive the real server's `/rpc` endpoint directly (a minimal frame probe
 * over a Node WebSocket — the same wire the web `RpcClientTransport` speaks) so
 * we can assert on raw `seq` numbers, which the browser UI hides. The streaming
 * non-negotiable itself is covered end-to-end through the browser by chat.spec
 * with the flag defaulting to `rpc`; this spec proves the seq/replay/snapshot
 * contract is byte-identical to legacy:
 *
 *   1. resubscribe with a `lastSeq` still in the ring → the exact tail replays,
 *      with NO missed and NO duplicated seqs.
 *   2. resubscribe with a `lastSeq` the ring has EVICTED → a full snapshot, not a
 *      partial replay with a gap.
 *   3. a reconnect DURING an active streaming turn continues without a gap.
 *
 * The ring is shrunk to 8 (AGENT_DECK_PUSH_BUS_CAPACITY) so eviction is reachable
 * without emitting thousands of events; the scripted reply is long enough that a
 * turn overflows that ring.
 */

// A long reply → many `text_delta` events (one seq each), so a turn's seq count
// comfortably exceeds the 8-slot ring (forcing eviction of the earliest seqs).
const REPLY_WORDS = Array.from({ length: 26 }, (_, i) => `word${i + 1}`);
const SCRIPTED_REPLY = REPLY_WORDS.join(" ");
const RING_CAPACITY = 8;

interface ServerFrame {
  kind: "reply" | "hello_ok" | "push";
  id?: number;
  ok?: boolean;
  error?: string;
  sessions?: unknown[];
  message?: { type: string; sessionId?: string; seq?: number };
}

/**
 * A minimal Effect-RPC frame probe over a raw WebSocket: id-correlated requests
 * + a running log of `event`/`snapshot` pushes. Deliberately dependency-free so
 * it exercises exactly the server wire, independent of the client-runtime state
 * machine (which is unit-tested in packages/client-runtime).
 */
class RpcProbe {
  private readonly ws: WebSocket;
  private nextId = 1;
  private readonly pending = new Map<
    number,
    { resolve: (frame: ServerFrame) => void; reject: (error: Error) => void }
  >();
  readonly events: { seq: number }[] = [];
  readonly snapshots: { seq: number }[] = [];
  /** The `type` of every push, in arrival order (for "snapshot came first" checks). */
  readonly pushKinds: string[] = [];
  private lastPushAt = 0;

  private constructor(url: string) {
    this.ws = new WebSocket(url);
    this.ws.onmessage = (ev: MessageEvent) => this.onFrame(String(ev.data));
  }

  static connect(baseUrl: string): Promise<RpcProbe> {
    const url = `${baseUrl.replace(/^http/, "ws")}/rpc`;
    const probe = new RpcProbe(url);
    return new Promise<RpcProbe>((resolve, reject) => {
      probe.ws.onopen = () => resolve(probe);
      probe.ws.onerror = () => reject(new Error(`failed to open ${url}`));
    });
  }

  private onFrame(raw: string): void {
    const frame = JSON.parse(raw) as ServerFrame;
    if (frame.kind === "push" && frame.message) {
      this.lastPushAt = Date.now();
      this.pushKinds.push(frame.message.type);
      if (frame.message.type === "event" && typeof frame.message.seq === "number") {
        this.events.push({ seq: frame.message.seq });
      } else if (frame.message.type === "snapshot" && typeof frame.message.seq === "number") {
        this.snapshots.push({ seq: frame.message.seq });
      }
      return;
    }
    if (frame.id !== undefined) {
      const entry = this.pending.get(frame.id);
      if (!entry) return;
      this.pending.delete(frame.id);
      if (frame.kind === "reply" && frame.ok === false) {
        entry.reject(new Error(frame.error ?? "rpc error"));
      } else {
        entry.resolve(frame);
      }
    }
  }

  request(request: unknown): Promise<ServerFrame> {
    const id = this.nextId++;
    return new Promise<ServerFrame>((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, request }));
    });
  }

  subscribe(sessionId: string, lastSeq?: number): Promise<ServerFrame> {
    return this.request({
      type: "subscribe_session",
      sessionId,
      ...(lastSeq !== undefined ? { lastSeq } : {}),
    });
  }

  get seqs(): number[] {
    return this.events.map((e) => e.seq);
  }

  /** Resolve once no push has arrived for `quietMs`, after at least one push. */
  async waitForQuiescence(quietMs = 700, timeoutMs = 30_000): Promise<void> {
    const start = Date.now();
    // Wait for the first push.
    while (this.lastPushAt === 0 && Date.now() - start < timeoutMs) {
      await delay(30);
    }
    while (Date.now() - start < timeoutMs) {
      if (this.lastPushAt !== 0 && Date.now() - this.lastPushAt >= quietMs) return;
      await delay(30);
    }
  }

  /** Resolve once at least `n` events have been observed. */
  async waitForEvents(n: number, timeoutMs = 30_000): Promise<void> {
    const start = Date.now();
    while (this.events.length < n && Date.now() - start < timeoutMs) {
      await delay(20);
    }
  }

  close(): void {
    this.ws.close();
  }
}

const delay = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

/** Assert a seq list is strictly +1 contiguous (no gap, no duplicate). */
function expectContiguous(seqs: number[]): void {
  for (let i = 1; i < seqs.length; i++) {
    expect(seqs[i], `seqs not contiguous at index ${i}: ${JSON.stringify(seqs)}`).toBe(
      seqs[i - 1]! + 1,
    );
  }
}

async function createSession(baseUrl: string): Promise<string> {
  const response = await fetch(`${baseUrl}/sessions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({}),
  });
  const { session } = (await response.json()) as { session: { id: string } };
  return session.id;
}

let harness: E2eHarness;

test.beforeAll(async () => {
  process.env.AGENT_DECK_PUSH_BUS_CAPACITY = String(RING_CAPACITY);
  harness = await startHarness({ reply: () => SCRIPTED_REPLY, chunkDelayMs: 70 });
});

test.afterAll(async () => {
  await harness.close();
  delete process.env.AGENT_DECK_PUSH_BUS_CAPACITY;
});

test("replay: resubscribe with an in-ring lastSeq replays the exact tail, no gap or dup", async () => {
  const sessionId = await createSession(harness.baseUrl);

  const a = await RpcProbe.connect(harness.baseUrl);
  await a.subscribe(sessionId); // fresh → snapshot
  expect(a.snapshots.length).toBe(1);
  await a.request({ type: "prompt", sessionId, message: "stream please" });
  await a.waitForQuiescence();

  const full = a.seqs;
  expect(full.length).toBeGreaterThan(RING_CAPACITY + 1); // the turn overflowed the ring
  expectContiguous(full);

  // A lastSeq safely inside the retained window (4th from the end ≤ ring of 8).
  const lastSeq = full[full.length - 4]!;

  const b = await RpcProbe.connect(harness.baseUrl);
  await b.subscribe(sessionId, lastSeq);
  await delay(400); // replay is synchronous; let the frames land

  // Replay, not snapshot: the ring still holds these seqs.
  expect(b.snapshots.length).toBe(0);
  expect(b.seqs).toEqual(full.filter((s) => s > lastSeq));
  expectContiguous(b.seqs);
  // No duplicate and no seq at/below the resubscribe watermark.
  expect(b.seqs.every((s) => s > lastSeq)).toBe(true);
  expect(new Set(b.seqs).size).toBe(b.seqs.length);

  a.close();
  b.close();
});

test("eviction: resubscribe with an evicted lastSeq falls back to a full snapshot", async () => {
  const sessionId = await createSession(harness.baseUrl);

  const a = await RpcProbe.connect(harness.baseUrl);
  await a.subscribe(sessionId);
  await a.request({ type: "prompt", sessionId, message: "stream please" });
  await a.waitForQuiescence();

  const full = a.seqs;
  const finalSeq = full.at(-1)!;
  expect(full.length).toBeGreaterThan(RING_CAPACITY + 1); // earliest seqs are evicted

  // lastSeq = 1 is far below the retained window → the ring can't replay it.
  const b = await RpcProbe.connect(harness.baseUrl);
  await b.subscribe(sessionId, 1);
  await delay(400);

  // A snapshot (carrying the FULL state at finalSeq), and NO replayed events.
  expect(b.snapshots.length).toBe(1);
  expect(b.snapshots[0]!.seq).toBe(finalSeq);
  expect(b.events.length).toBe(0);
  // The snapshot arrived first (before any live event would).
  expect(b.pushKinds[0]).toBe("snapshot");

  a.close();
  b.close();
});

test("reconnect mid-turn: a drop during an active stream resumes with no gap or dup", async () => {
  const sessionId = await createSession(harness.baseUrl);

  const a = await RpcProbe.connect(harness.baseUrl);
  await a.subscribe(sessionId);
  await a.request({ type: "prompt", sessionId, message: "stream please" });

  // Disconnect mid-stream: after a few events but well before the turn ends.
  await a.waitForEvents(3);
  const seenBeforeDrop = a.seqs;
  const watermark = seenBeforeDrop.at(-1)!;
  a.close();

  // Reconnect and resume from the last seq we applied (what the web transport
  // does on reconnect via onConnected).
  const b = await RpcProbe.connect(harness.baseUrl);
  await b.subscribe(sessionId, watermark);
  await b.waitForQuiescence();

  // The pre-drop prefix is contiguous and starts at 1.
  expectContiguous(seenBeforeDrop);
  expect(seenBeforeDrop[0]).toBe(1);

  // The resume delivered the rest with no gap across the boundary. The ring may
  // have evicted the watermark during the (brief) gap → snapshot fallback; that
  // is ALSO gapless (it carries the full state), so accept either path.
  if (b.snapshots.length > 0) {
    expect(b.snapshots[0]!.seq).toBeGreaterThanOrEqual(watermark);
  } else {
    expect(b.seqs[0]).toBe(watermark + 1); // resume begins exactly after the watermark
    expectContiguous(b.seqs);
    expect(new Set(b.seqs).size).toBe(b.seqs.length); // no duplicate
    // The union across the reconnect is one contiguous run, no gap, no dup.
    const union = [...seenBeforeDrop, ...b.seqs];
    expectContiguous(union);
    expect(new Set(union).size).toBe(union.length);
  }

  a.close();
  b.close();
});
