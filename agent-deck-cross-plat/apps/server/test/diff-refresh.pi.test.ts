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
 * Slice 9 full-stack gate against a REAL pi binary: a session whose cwd is a
 * real git repo runs a turn, the test mutates the working tree, and the next
 * turn boundary refreshes the changed-file set — diff_refreshed receipt, the
 * diff_push broadcast, and the diff_files / diff_file RPC ops all observed
 * over the real `/rpc` socket (server.pi.test.ts harness conventions).
 */

process.env.AGENT_DECK_TEST = "1";

let mock: MockProviderServer;
let server: AgentDeckServer;
let sessionId: string;

const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const repo = mkdtempSync(path.join(tmpdir(), "pi-diff-repo-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));

/** Frame-level RPC client: keeps every server frame (diff pushes included). */
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

describe("diff engine over the real stack (Slice 9)", () => {
  it("a turn boundary after a working-tree change emits diff_refreshed + the diff_push", async () => {
    const client = new RpcFrameClient(server.port);
    await client.open();

    // Turn 1 in a CLEAN tree: idle fires, but the changed-file set is empty
    // vs the empty baseline — no diff_refreshed yet.
    client.send({ type: "prompt", sessionId, message: "turn one" });
    await server.receipts.waitFor("idle", sessionId);

    // The working tree changes between turns (as if the agent wrote a file).
    writeFileSync(path.join(repo, "turn-output.txt"), "written by the turn\n");

    // Turn 2: the boundary refresh sees the new file → receipt + push.
    client.send({ type: "prompt", sessionId, message: "turn two" });
    await server.receipts.waitFor("diff_refreshed", sessionId);

    const push = await client.waitFor(
      (f) =>
        f.kind === "diff_push" &&
        (f.message as { sessionId?: string } | undefined)?.sessionId === sessionId,
    );
    const message = push.message as {
      type: string;
      repo: boolean;
      files: Array<{ path: string; status: string }>;
    };
    expect(message.type).toBe("diff_changed");
    expect(message.repo).toBe(true);
    expect(message.files.some((f) => f.path === "turn-output.txt" && f.status === "?")).toBe(true);

    client.close();
  });

  it("diff_files and diff_file answer over the real socket", async () => {
    const client = new RpcFrameClient(server.port);
    await client.open();

    const filesId = client.send({ type: "diff_files", sessionId });
    const filesFrame = await client.waitFor((f) => f.kind === "diff_files_ok" && f.id === filesId);
    const files = filesFrame.files as Array<{ path: string; insertions: number | null }>;
    expect(filesFrame.repo).toBe(true);
    const entry = files.find((f) => f.path === "turn-output.txt");
    expect(entry).toBeDefined();
    expect(entry!.insertions).toBe(1);

    const diffId = client.send({ type: "diff_file", sessionId, path: "turn-output.txt" });
    const diffFrame = await client.waitFor((f) => f.kind === "diff_file_ok" && f.id === diffId);
    expect(diffFrame.binary).toBe(false);
    expect(diffFrame.truncated).toBe(false);
    expect(String(diffFrame.diff)).toContain("+written by the turn");

    client.close();
  });
});
