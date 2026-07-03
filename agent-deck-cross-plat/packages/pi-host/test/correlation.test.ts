import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { PiRpcError, PiSession, type PiInboundEvent } from "../src/PiSession.ts";

const FIXTURE = path.join(path.dirname(fileURLToPath(import.meta.url)), "fixtures", "fake-pi.cjs");

let sessions: PiSession[] = [];

function makeSession(requestTimeoutMs = 5_000): PiSession {
  const session = new PiSession({
    binPath: process.execPath,
    args: [FIXTURE],
    cwd: process.cwd(),
    requestTimeoutMs,
  });
  session.start();
  sessions.push(session);
  return session;
}

afterEach(async () => {
  await Promise.all(sessions.map((s) => s.stop()));
  sessions = [];
});

describe("PiSession request/response correlation", () => {
  it("resolves a request with its correlated response data", async () => {
    const session = makeSession();
    const state = await session.getState();
    expect(state.sessionId).toBe("fake-session");
    expect(state.isStreaming).toBe(false);
  });

  it("interleaves concurrent requests by id", async () => {
    const session = makeSession();
    const [state, named] = await Promise.all([
      session.getState(),
      session.setSessionName("ok"),
      session.getState(),
    ]);
    expect(state.sessionId).toBe("fake-session");
    expect(named).toBeUndefined();
  });

  it("rejects with PiRpcError carrying pi's error message on success:false", async () => {
    const session = makeSession();
    await expect(session.setSessionName("fail")).rejects.toThrow("boom");
    await expect(session.setSessionName("fail")).rejects.toBeInstanceOf(PiRpcError);
  });

  it("rejects on timeout when pi never responds", async () => {
    const session = makeSession(200);
    await expect(session.request({ type: "compact" })).rejects.toThrow(/within 200ms/);
  });

  it("rejects pending requests when the process exits", async () => {
    const session = makeSession();
    await expect(session.abort()).rejects.toThrow(/exited/);
  });

  it("streams events in order and surfaces malformed lines without breaking the stream", async () => {
    const session = makeSession();
    const events: PiInboundEvent[] = [];
    const malformed: string[] = [];
    session.on("event", (event) => events.push(event));
    session.on("malformed-line", (line) => malformed.push(line));

    await session.prompt("hi");
    await new Promise<void>((resolve) => {
      session.on("event", (event) => {
        if ((event as { type: string }).type === "agent_end") resolve();
      });
    });

    const types = events.map((event) => (event as { type: string }).type);
    expect(types).toEqual(["turn_start", "message_update", "message_update", "agent_end"]);
    expect(malformed).toEqual(["this is not json"]);
  });
});
