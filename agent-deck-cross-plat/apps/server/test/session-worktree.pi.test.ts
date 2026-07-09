import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  MOCK_MODEL_ID,
  MOCK_PROVIDER_ID,
  startMockProvider,
  writeMockProviderExtension,
  type MockProviderServer,
} from "@agent-deck/testkit";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * Session worktree isolation (native piAgentSessionsUseWorktree): with the
 * setting on and the project a git repo, a new session runs in its OWN worktree
 * on an `agent-deck/session-<id>` branch (cwd = the worktree), and deleting the
 * session removes that worktree. With the setting off, the session runs in the
 * project root.
 */

process.env.AGENT_DECK_TEST = "1";

let mock: MockProviderServer;
let server: AgentDeckServer;
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));
const repoDir = mkdtempSync(path.join(tmpdir(), "wt-repo-"));

function git(args: string[]): void {
  execFileSync("git", args, { cwd: repoDir, stdio: "ignore" });
}

async function patchSettings(body: unknown): Promise<Response> {
  return fetch(`http://127.0.0.1:${server.port}/settings`, {
    method: "PATCH",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

interface SessionResp {
  id: string;
  cwd: string;
  worktreeBranch?: string;
  worktreeSourceBranch?: string;
}

async function createSession(projectId: string): Promise<SessionResp> {
  const res = await fetch(`http://127.0.0.1:${server.port}/sessions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      projectId,
      provider: MOCK_PROVIDER_ID,
      model: MOCK_MODEL_ID,
      extensions: [process.env.AGENT_DECK_PROVIDER_EXTENSIONS],
      env: { HOME: tmpHome, USERPROFILE: tmpHome, PI_SKIP_VERSION_CHECK: "1" },
    }),
  });
  expect(res.status).toBe(201);
  const { session } = (await res.json()) as { session: SessionResp };
  return session;
}

beforeAll(async () => {
  // A real git repo on branch `main` with one commit — the isolation source.
  git(["init", "-b", "main"]);
  git(["config", "user.email", "t@example.com"]);
  git(["config", "user.name", "Test"]);
  writeFileSync(path.join(repoDir, "README.md"), "# repo\n");
  git(["add", "-A"]);
  git(["commit", "-m", "init"]);

  mock = await startMockProvider({ reply: () => "ok" });
  process.env.AGENT_DECK_PROVIDER_EXTENSIONS = writeMockProviderExtension(mock.baseUrl);
  server = await startServer({ dataDir });
});

afterAll(async () => {
  await server.close();
  await mock.close();
  delete process.env.AGENT_DECK_PROVIDER_EXTENSIONS;
});

async function addProject(): Promise<string> {
  const res = await fetch(`http://127.0.0.1:${server.port}/projects`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ path: repoDir }),
  });
  const { project } = (await res.json()) as { project: { id: string } };
  return project.id;
}

describe("session worktree isolation", () => {
  it("runs a session in its own worktree + branch when the setting is on, and cleans it up on delete", async () => {
    const projectId = await addProject();
    expect((await patchSettings({ worktreeIsolation: true })).status).toBe(200);

    const session = await createSession(projectId);
    // cwd is an isolated worktree under the data dir, NOT the project root.
    expect(session.cwd).not.toBe(repoDir);
    expect(session.cwd.startsWith(path.join(dataDir, "session-worktrees"))).toBe(true);
    expect(session.worktreeBranch).toMatch(/^agent-deck\/session-/);
    expect(session.worktreeSourceBranch).toBe("main");
    expect(existsSync(session.cwd)).toBe(true);
    // It's a real git worktree (the branch checked out there is the session branch).
    const branch = execFileSync("git", ["rev-parse", "--abbrev-ref", "HEAD"], {
      cwd: session.cwd,
    })
      .toString()
      .trim();
    expect(branch).toBe(session.worktreeBranch);

    // pi launched + responded inside the worktree.
    const managed = server.sessions.get(session.id)!;
    await managed.prompt("hello");
    await server.receipts.waitFor("idle", session.id);

    // Deleting the session removes the worktree directory.
    const del = await fetch(`http://127.0.0.1:${server.port}/sessions/${session.id}`, {
      method: "DELETE",
    });
    expect(del.status).toBe(200);
    expect(existsSync(session.cwd)).toBe(false);
  });

  it("runs in the project root when the setting is off (no worktree)", async () => {
    const projectId = await addProject();
    expect((await patchSettings({ worktreeIsolation: false })).status).toBe(200);

    const session = await createSession(projectId);
    expect(session.cwd).toBe(repoDir);
    expect(session.worktreeBranch).toBeUndefined();
  });
});
