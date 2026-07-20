import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import type { ServerMessage } from "@agent-deck/domain";
import {
  MOCK_MODEL_ID,
  MOCK_PROVIDER_ID,
  startMockProvider,
  writeMockProviderExtension,
  type MockProviderServer,
} from "@agent-deck/testkit";
import { WebSocket } from "ws";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * Full-stack slice-4 gate: REST creates a session backed by a REAL pi binary,
 * a WS client subscribes and prompts, and streaming arrives over the socket as
 * ordered, seq-stamped domain events. A second client replays from mid-stream.
 *
 * The socket speaks the Effect-RPC `/rpc` framing (the legacy `/ws` envelope was
 * retired in Slice 7c): the {@link WsClient} helper wraps each command as a
 * request frame and unwraps server frames back into bare `ServerMessage`s —
 * `push` frames carry the domain-event/snapshot stream verbatim, and a failed
 * `reply` becomes a synthetic `{ type: "error" }` message, exactly as the web
 * `RpcClientTransport` surfaces server errors.
 */

process.env.AGENT_DECK_TEST = "1";

const SCRIPTED_REPLY = "Server slice streams each word over the websocket bridge";

let mock: MockProviderServer;
let server: AgentDeckServer;
let sessionId: string;

const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const cwd = mkdtempSync(path.join(tmpdir(), "pi-server-it-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));

class WsClient {
  readonly messages: ServerMessage[] = [];
  private readonly socket: WebSocket;
  private readonly waiters: Array<{
    predicate: (m: ServerMessage) => boolean;
    resolve: (m: ServerMessage) => void;
  }> = [];

  private nextId = 1;

  constructor(port: number) {
    this.socket = new WebSocket(`ws://127.0.0.1:${port}/rpc`);
    this.socket.on("message", (raw: Buffer) => {
      const frame = JSON.parse(raw.toString("utf8")) as {
        kind: "push" | "reply" | "hello_ok";
        message?: ServerMessage;
        ok?: boolean;
        error?: string;
      };
      // Unwrap RPC server frames into the bare ServerMessage surface the test
      // asserts on: a `push` carries the event/snapshot stream verbatim; a
      // failed `reply` becomes a synthetic error message (as the web transport
      // does); acks (`reply` ok:true) and `hello_ok` are not exercised here.
      let message: ServerMessage | null = null;
      if (frame.kind === "push" && frame.message) {
        message = frame.message;
      } else if (frame.kind === "reply" && frame.ok === false) {
        message = { type: "error", message: frame.error ?? "rpc error" };
      }
      if (!message) return;
      this.messages.push(message);
      for (let i = this.waiters.length - 1; i >= 0; i -= 1) {
        if (this.waiters[i]!.predicate(message)) {
          const [waiter] = this.waiters.splice(i, 1);
          waiter!.resolve(message);
        }
      }
    });
  }

  async open(): Promise<void> {
    await new Promise<void>((resolve) => this.socket.once("open", resolve));
  }

  /** Send one client command, wrapped as an id-correlated RPC request frame. */
  send(request: unknown): void {
    this.socket.send(JSON.stringify({ id: this.nextId++, request }));
  }

  async waitFor(
    predicate: (m: ServerMessage) => boolean,
    timeoutMs = 30_000,
  ): Promise<ServerMessage> {
    const existing = this.messages.find(predicate);
    if (existing) return existing;
    return await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("waitFor timed out")), timeoutMs);
      this.waiters.push({
        predicate,
        resolve: (m) => {
          clearTimeout(timer);
          resolve(m);
        },
      });
    });
  }

  close(): void {
    this.socket.close();
  }
}

beforeAll(async () => {
  mock = await startMockProvider({ reply: () => SCRIPTED_REPLY });
  server = await startServer({ dataDir });
});

afterAll(async () => {
  await server.close();
  await mock.close();
});

describe("server: REST + WS against real pi", () => {
  it("creates a session over REST", async () => {
    const response = await fetch(`http://127.0.0.1:${server.port}/sessions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        cwd,
        provider: MOCK_PROVIDER_ID,
        model: MOCK_MODEL_ID,
        extensions: [writeMockProviderExtension(mock.baseUrl)],
        env: { HOME: tmpHome, USERPROFILE: tmpHome, PI_SKIP_VERSION_CHECK: "1" },
      }),
    });
    expect(response.status).toBe(201);
    const body = (await response.json()) as { session: { id: string; cwd: string } };
    sessionId = body.session.id;
    expect(body.session.cwd).toBe(cwd);
  });

  it("streams seq-stamped cell_deltas over the websocket before the final cell", async () => {
    const client = new WsClient(server.port);
    await client.open();
    client.send({ type: "subscribe_session", sessionId });
    await client.waitFor((m) => m.type === "snapshot");

    client.send({ type: "prompt", sessionId, message: "hello over ws" });
    await server.receipts.waitFor("idle", sessionId);
    await client.waitFor(
      (m) => m.type === "event" && m.event.type === "agent_status" && m.event.status === "idle",
    );

    const events = client.messages.filter((m) => m.type === "event");
    const seqs = events.map((m) => m.seq);
    expect(seqs).toEqual([...seqs].sort((a, b) => a - b));
    expect(new Set(seqs).size).toBe(seqs.length);

    const finalIndex = events.findIndex(
      (m) => m.event.type === "cell_final" && m.event.cell.kind === "assistant",
    );
    const deltas = events
      .slice(0, finalIndex)
      .filter((m) => m.event.type === "cell_delta")
      .map((m) => (m.event.type === "cell_delta" ? m.event.delta : ""));
    expect(deltas.length).toBeGreaterThanOrEqual(2);
    expect(deltas.join("")).toBe(SCRIPTED_REPLY);
    client.close();
  });

  it("replays from a mid-stream seq for a reconnecting client", async () => {
    const session = server.sessions.get(sessionId)!;
    const { seq: lastSeq } = session.snapshot();
    const midSeq = Math.floor(lastSeq / 2);

    const client = new WsClient(server.port);
    await client.open();
    client.send({ type: "subscribe_session", sessionId, lastSeq: midSeq });
    await client.waitFor((m) => m.type === "event" && m.seq === lastSeq);

    const events = client.messages.filter((m) => m.type === "event");
    expect(events[0]!.seq).toBe(midSeq + 1);
    expect(events.at(-1)!.seq).toBe(lastSeq);
    expect(client.messages.some((m) => m.type === "snapshot")).toBe(false);
    client.close();
  });

  it("falls back to a snapshot when the requested seq is unknown", async () => {
    const client = new WsClient(server.port);
    await client.open();
    // A fresh subscribe (no lastSeq) must yield a snapshot with the full transcript.
    client.send({ type: "subscribe_session", sessionId });
    const snapshot = await client.waitFor((m) => m.type === "snapshot");
    if (snapshot.type !== "snapshot") throw new Error("unreachable");
    const assistant = snapshot.state.cells.find((c) => c.kind === "assistant");
    expect(assistant).toMatchObject({
      blocks: [{ kind: "text", text: SCRIPTED_REPLY, done: true }],
    });
    client.close();
  });

  it("rejects malformed and unknown-session messages with error frames", async () => {
    const client = new WsClient(server.port);
    await client.open();
    client.send({ type: "prompt", sessionId: "nope", message: "x" });
    const unknown = await client.waitFor((m) => m.type === "error");
    expect(unknown.type === "error" && unknown.message).toContain("unknown session");
    client.send("garbage");
    await client.waitFor((m) => m.type === "error" && m.message.includes("invalid message"));
    client.close();
  });
});
