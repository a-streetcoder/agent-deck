import { describe, expect, it, vi } from "vitest";
import { Schema } from "effect";
import { RpcServerFrame } from "@agent-deck/contracts";
import type { RpcServerFrame as Frame } from "@agent-deck/contracts";
import { createRpcConnection } from "../src/rpcHandler.ts";
import type { ManagedSession, SessionManager } from "../src/SessionManager.ts";
import type { StampedEvent } from "../src/services/pushBus.ts";

/**
 * Unit tests for the Effect-RPC connection core (rpcHandler.ts) — the same
 * operation surface + seq/replay/snapshot semantics as the legacy `/ws`
 * envelope, exercised against a fake SessionManager with a plain `send`
 * collector (no `ws`, no runtime). Every outbound frame is asserted to be a
 * contract-valid `RpcServerFrame`.
 */

const decodeFrame = Schema.decodeUnknownEither(RpcServerFrame);

interface FakeBus {
  subscribe: (fn: (s: StampedEvent) => void) => () => void;
  emit: (event: StampedEvent) => void;
  replayFrom: (lastSeq: number) => StampedEvent[] | null;
}

function makeSession(
  id: string,
  opts?: {
    replay?: StampedEvent[] | null;
    snapshot?: { seq: number; state: unknown };
  },
) {
  let subscriber: ((s: StampedEvent) => void) | null = null;
  const unsubscribe = vi.fn();
  const bus: FakeBus = {
    subscribe: (fn) => {
      subscriber = fn;
      return unsubscribe;
    },
    emit: (event) => subscriber?.(event),
    replayFrom: () => opts?.replay ?? null,
  };
  const ops = {
    prompt: vi.fn(async () => {}),
    steer: vi.fn(async () => {}),
    abort: vi.fn(async () => {}),
    compact: vi.fn(async () => {}),
    setModel: vi.fn(async () => {}),
    setThinkingLevel: vi.fn(async () => {}),
    respondToUiRequest: vi.fn(),
    getAvailableModels: vi.fn(async () => [{ provider: "anthropic", id: "sonnet" }]),
  };
  const session = {
    meta: { id, cwd: "/tmp", createdAt: "2026-01-01T00:00:00.000Z" },
    bus: {
      subscribe: bus.subscribe,
      replayFrom: bus.replayFrom,
      get lastSeq() {
        return 0;
      },
    },
    onExit: () => () => {},
    snapshot: () => opts?.snapshot ?? { seq: 0, state: { cells: [] } },
    ...ops,
  } as unknown as ManagedSession;
  return { session, bus, unsubscribe, ops };
}

function makeManager(sessions: Record<string, ManagedSession>, list: unknown[] = []) {
  return {
    get: (id: string) => sessions[id],
    list: () => list,
  } as unknown as SessionManager;
}

function harness(manager: SessionManager) {
  const frames: Frame[] = [];
  const conn = createRpcConnection({
    sessions: manager,
    send: (frame) => {
      // Assert every outbound frame is contract-valid.
      expect(decodeFrame(frame)._tag, JSON.stringify(frame)).toBe("Right");
      frames.push(frame);
    },
  });
  return { conn, frames };
}

const frame = (id: number, request: unknown) => JSON.stringify({ id, request });

describe("createRpcConnection", () => {
  it("hello replies hello_ok with the session list", async () => {
    const list = [{ id: "s1", cwd: "/tmp", createdAt: "2026-01-01T00:00:00.000Z" }];
    const { conn, frames } = harness(makeManager({}, list));
    await conn.handleMessage(frame(7, { type: "hello" }));
    expect(frames).toEqual([{ kind: "hello_ok", id: 7, sessions: list }]);
  });

  it("unknown session replies with an error", async () => {
    const { conn, frames } = harness(makeManager({}));
    await conn.handleMessage(frame(1, { type: "abort", sessionId: "nope" }));
    expect(frames).toEqual([{ kind: "reply", id: 1, ok: false, error: "unknown session" }]);
  });

  it("subscribe_session with no lastSeq pushes a snapshot then acks", async () => {
    const { session } = makeSession("s1", { snapshot: { seq: 5, state: { cells: ["x"] } } });
    const { conn, frames } = harness(makeManager({ s1: session }));
    await conn.handleMessage(frame(2, { type: "subscribe_session", sessionId: "s1" }));
    expect(frames).toEqual([
      {
        kind: "push",
        message: { type: "snapshot", sessionId: "s1", seq: 5, state: { cells: ["x"] } },
      },
      { kind: "reply", id: 2, ok: true },
    ]);
  });

  it("subscribe_session with lastSeq replays from the ring (no snapshot)", async () => {
    const replay: StampedEvent[] = [
      { seq: 3, event: { kind: "text_delta" } as unknown as StampedEvent["event"] },
      { seq: 4, event: { kind: "text_delta" } as unknown as StampedEvent["event"] },
    ];
    const { session } = makeSession("s1", { replay });
    const { conn, frames } = harness(makeManager({ s1: session }));
    await conn.handleMessage(frame(3, { type: "subscribe_session", sessionId: "s1", lastSeq: 2 }));
    expect(frames.map((f) => (f.kind === "push" ? f.message.type : f.kind))).toEqual([
      "event",
      "event",
      "reply",
    ]);
    expect(frames[0]).toMatchObject({ kind: "push", message: { seq: 3 } });
    expect(frames[1]).toMatchObject({ kind: "push", message: { seq: 4 } });
  });

  it("subscribe_session with an evicted lastSeq falls back to a snapshot", async () => {
    const { session } = makeSession("s1", { replay: null, snapshot: { seq: 9, state: {} } });
    const { conn, frames } = harness(makeManager({ s1: session }));
    await conn.handleMessage(frame(4, { type: "subscribe_session", sessionId: "s1", lastSeq: 1 }));
    expect(frames[0]).toMatchObject({ kind: "push", message: { type: "snapshot", seq: 9 } });
    expect(frames[1]).toEqual({ kind: "reply", id: 4, ok: true });
  });

  it("live bus events after subscribe are pushed as frames", async () => {
    const { session, bus } = makeSession("s1");
    const { conn, frames } = harness(makeManager({ s1: session }));
    await conn.handleMessage(frame(5, { type: "subscribe_session", sessionId: "s1" }));
    frames.length = 0;
    bus.emit({ seq: 11, event: { kind: "text_delta" } as unknown as StampedEvent["event"] });
    expect(frames).toEqual([
      {
        kind: "push",
        message: { type: "event", sessionId: "s1", seq: 11, event: { kind: "text_delta" } },
      },
    ]);
  });

  it("re-subscribing replaces the old subscription", async () => {
    const { session, unsubscribe } = makeSession("s1");
    const { conn } = harness(makeManager({ s1: session }));
    await conn.handleMessage(frame(1, { type: "subscribe_session", sessionId: "s1" }));
    expect(unsubscribe).not.toHaveBeenCalled();
    await conn.handleMessage(frame(2, { type: "subscribe_session", sessionId: "s1" }));
    expect(unsubscribe).toHaveBeenCalledTimes(1);
  });

  it("close() releases all subscriptions", async () => {
    const { session, unsubscribe } = makeSession("s1");
    const { conn } = harness(makeManager({ s1: session }));
    await conn.handleMessage(frame(1, { type: "subscribe_session", sessionId: "s1" }));
    conn.close();
    expect(unsubscribe).toHaveBeenCalledTimes(1);
  });

  it("abort invokes the op and acks", async () => {
    const { session, ops } = makeSession("s1");
    const { conn, frames } = harness(makeManager({ s1: session }));
    await conn.handleMessage(frame(6, { type: "abort", sessionId: "s1" }));
    expect(ops.abort).toHaveBeenCalledTimes(1);
    expect(frames).toEqual([{ kind: "reply", id: 6, ok: true }]);
  });

  it("prompt forwards message + images and acks", async () => {
    const { session, ops } = makeSession("s1");
    const { conn, frames } = harness(makeManager({ s1: session }));
    const images = [{ type: "image", data: "aGk=", mimeType: "image/png" }];
    await conn.handleMessage(frame(1, { type: "prompt", sessionId: "s1", message: "hi", images }));
    expect(ops.prompt).toHaveBeenCalledWith("hi", images);
    expect(frames).toEqual([{ kind: "reply", id: 1, ok: true }]);
  });

  it("set_model rejects a model pi does not offer", async () => {
    const { session, ops } = makeSession("s1");
    const { conn, frames } = harness(makeManager({ s1: session }));
    await conn.handleMessage(
      frame(1, { type: "set_model", sessionId: "s1", provider: "openai", modelId: "gpt" }),
    );
    expect(ops.setModel).not.toHaveBeenCalled();
    expect(frames).toEqual([
      { kind: "reply", id: 1, ok: false, error: "unknown model: openai/gpt" },
    ]);
  });

  it("an op that throws yields an error reply", async () => {
    const { session, ops } = makeSession("s1");
    ops.abort.mockRejectedValueOnce(new Error("boom"));
    const { conn, frames } = harness(makeManager({ s1: session }));
    await conn.handleMessage(frame(1, { type: "abort", sessionId: "s1" }));
    expect(frames).toEqual([{ kind: "reply", id: 1, ok: false, error: "Error: boom" }]);
  });

  it("a malformed frame is rejected at the boundary with a best-effort id", async () => {
    const { conn, frames } = harness(makeManager({}));
    // valid id, but the request fails ClientMessage decode
    await conn.handleMessage(frame(8, { type: "nonsense" }));
    expect(frames).toEqual([{ kind: "reply", id: 8, ok: false, error: "invalid message" }]);
  });

  it("ui_response with an exotic (Date-like) payload is rejected by the contract", async () => {
    const { session, ops } = makeSession("s1");
    const { conn, frames } = harness(makeManager({ s1: session }));
    // A JSON array is not a plain object → PlainJsonRecord rejects it.
    await conn.handleMessage(frame(9, { type: "ui_response", sessionId: "s1", response: [] }));
    expect(ops.respondToUiRequest).not.toHaveBeenCalled();
    expect(frames).toEqual([{ kind: "reply", id: 9, ok: false, error: "invalid message" }]);
  });

  it("non-JSON input yields an invalid-JSON reply", async () => {
    const { conn, frames } = harness(makeManager({}));
    await conn.handleMessage("}{ not json");
    expect(frames).toEqual([{ kind: "reply", id: 0, ok: false, error: "invalid JSON" }]);
  });
});
