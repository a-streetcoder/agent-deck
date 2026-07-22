import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
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
 * Slice 18a full-stack gate against a REAL pi binary: a session whose cwd is a
 * real git repo runs two turns, each modifying the working tree, and each idle
 * turn-boundary captures a checkpoint — the checkpoint_captured receipt fires
 * per turn, `checkpoints_list` answers over the real `/rpc` socket with a
 * checkpoint per turn (labeled with that turn's user message, hasFiles=true),
 * and the pre-existing idle receipts still fire on time (capture is forked
 * fire-and-forget off the idle boundary). Mirrors diff-refresh.pi.test.ts.
 */

process.env.AGENT_DECK_TEST = "1";

let mock: MockProviderServer;
let server: AgentDeckServer;
let sessionId: string;

const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const repo = mkdtempSync(path.join(tmpdir(), "pi-ckpt-repo-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));

/** Frame-level RPC client (keeps every server frame). */
class RpcFrameClient {
  readonly frames: Array<Record<string, unknown>> = [];
  private readonly socket: WebSocket;
  private readonly waiters: Array<{
    predicate: (f: Record<string, unknown>) => boolean;
    resolve: (f: Record<string, unknown>) => void;
  }> = [];
  private nextId = 1;

  constructor(port: number) {
    this.socket = new WebSocket(`ws://127.0.0.1:${port}/rpc`);
    this.socket.on("message", (raw: Buffer) => {
      const frame = JSON.parse(raw.toString("utf8")) as Record<string, unknown>;
      this.frames.push(frame);
      for (let i = this.waiters.length - 1; i >= 0; i -= 1) {
        if (this.waiters[i]!.predicate(frame)) {
          const [waiter] = this.waiters.splice(i, 1);
          waiter!.resolve(frame);
        }
      }
    });
  }

  async open(): Promise<void> {
    await new Promise<void>((resolve) => this.socket.once("open", resolve));
  }

  send(request: unknown): number {
    const id = this.nextId++;
    this.socket.send(JSON.stringify({ id, request }));
    return id;
  }

  async waitFor(
    predicate: (f: Record<string, unknown>) => boolean,
    timeoutMs = 30_000,
  ): Promise<Record<string, unknown>> {
    const existing = this.frames.find(predicate);
    if (existing) return existing;
    return await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("waitFor timed out")), timeoutMs);
      this.waiters.push({
        predicate,
        resolve: (f) => {
          clearTimeout(timer);
          resolve(f);
        },
      });
    });
  }

  close(): void {
    this.socket.close();
  }
}

beforeAll(async () => {
  const git = (args: string[]): void => {
    execFileSync("git", args, { cwd: repo, stdio: "ignore" });
  };
  git(["init", "-b", "main"]);
  git(["config", "user.email", "t@example.com"]);
  git(["config", "user.name", "Test"]);
  writeFileSync(path.join(repo, "README.md"), "# scratch\n");
  git(["add", "-A"]);
  git(["commit", "-m", "init"]);

  mock = await startMockProvider({ reply: () => "done" });
  server = await startServer({ dataDir });

  const response = await fetch(`http://127.0.0.1:${server.port}/sessions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      cwd: repo,
      provider: MOCK_PROVIDER_ID,
      model: MOCK_MODEL_ID,
      extensions: [writeMockProviderExtension(mock.baseUrl)],
      env: { HOME: tmpHome, USERPROFILE: tmpHome, PI_SKIP_VERSION_CHECK: "1" },
    }),
  });
  expect(response.status).toBe(201);
  sessionId = ((await response.json()) as { session: { id: string } }).session.id;
});

afterAll(async () => {
  await server.close();
  await mock.close();
});

describe("checkpoint capture over the real stack (Slice 18a)", () => {
  it("captures a checkpoint per turn and lists them, idle receipts intact", async () => {
    const client = new RpcFrameClient(server.port);
    await client.open();

    // Turn 1: the boundary captures checkpoint 0 (the repo tree at turn 1).
    client.send({ type: "prompt", sessionId, message: "first checkpoint turn" });
    await server.receipts.waitFor("idle", sessionId);
    await server.receipts.waitFor("checkpoint_captured", sessionId);

    // The working tree changes between turns (as if the agent wrote a file).
    writeFileSync(path.join(repo, "turn-output.txt"), "written by the turn\n");

    // Turn 2: the boundary captures checkpoint 1 (the changed tree).
    client.send({ type: "prompt", sessionId, message: "second checkpoint turn" });
    // Two idle + two checkpoint_captured receipts total (per-turn cadence).
    await server.receipts.waitFor("idle", sessionId);
    await server.receipts.waitFor("checkpoint_captured", sessionId);

    // Poll the list until both captures have landed (capture is forked off idle,
    // so the receipt above races the index write on the same session chain).
    let checkpoints: Array<{ turnIndex: number; label: string; hasFiles: boolean }> = [];
    for (let attempt = 0; attempt < 40 && checkpoints.length < 2; attempt += 1) {
      const listId = client.send({ type: "checkpoints_list", sessionId });
      const frame = await client.waitFor(
        (f) => f.kind === "checkpoints_list_ok" && f.id === listId,
      );
      checkpoints = frame.checkpoints as typeof checkpoints;
      if (checkpoints.length < 2) await new Promise((r) => setTimeout(r, 100));
    }

    expect(checkpoints).toHaveLength(2);
    expect(checkpoints.map((c) => c.turnIndex)).toEqual([0, 1]);
    // The workspace half was captured for both (the session cwd is a git repo).
    expect(checkpoints.every((c) => c.hasFiles)).toBe(true);
    // The real pi reflects the user message into the transcript, so each
    // checkpoint is labeled with THAT turn's prompt.
    expect(checkpoints[0]!.label).toBe("first checkpoint turn");
    expect(checkpoints[1]!.label).toBe("second checkpoint turn");

    // The hidden checkpoint refs exist in the repo and never became branches.
    const refs = execFileSync(
      "git",
      ["for-each-ref", "--format=%(refname)", "refs/agent-deck/checkpoints/"],
      { cwd: repo, encoding: "utf8" },
    ).trim();
    expect(refs.split("\n")).toHaveLength(2);
    expect(execFileSync("git", ["branch", "--list"], { cwd: repo, encoding: "utf8" }).trim()).toBe(
      "* main",
    );

    client.close();
  });
});
