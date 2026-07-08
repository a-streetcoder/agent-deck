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
import { isLoopRunTerminal, type LoopRun } from "@agent-deck/domain";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * Loop run engine end-to-end against real pi: POST /loops/:name/run drives the
 * loop's agent (a real pi subagent, mock provider) each iteration and runs the
 * validation command. `exit 0` completes after one iteration; `exit 1` runs to
 * maxIterations then fails — the exit code is the deterministic stop control.
 */

process.env.AGENT_DECK_TEST = "1";

let mock: MockProviderServer;
let server: AgentDeckServer;
let projectId: string;
let base: string;
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const project = mkdtempSync(path.join(tmpdir(), "pi-loops-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));

beforeAll(async () => {
  mock = await startMockProvider({ reply: () => "Worked on the goal." });
  process.env.AGENT_DECK_PROVIDER_EXTENSIONS = writeMockProviderExtension(mock.baseUrl);
  server = await startServer({ dataDir });
  base = `http://127.0.0.1:${server.port}`;
  const created = (await (
    await fetch(`${base}/projects`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path: project }),
    })
  ).json()) as { project: { id: string } };
  projectId = created.project.id;
});

afterAll(async () => {
  await server.close();
  await mock.close();
  delete process.env.AGENT_DECK_PROVIDER_EXTENSIONS;
});

async function putLoop(
  name: string,
  validationCommand: string,
  maxIterations: number,
): Promise<void> {
  const res = await fetch(`${base}/loops`, {
    method: "PUT",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ name, goal: "Do the work.", validationCommand, maxIterations }),
  });
  expect(res.ok).toBe(true);
}

async function startRun(name: string): Promise<string> {
  const res = await fetch(`${base}/loops/${encodeURIComponent(name)}/run`, {
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
  const { run } = (await res.json()) as { run: LoopRun };
  return run.id;
}

async function getRun(id: string): Promise<LoopRun> {
  const res = await fetch(`${base}/loops/runs/${id}`);
  expect(res.ok).toBe(true);
  return ((await res.json()) as { run: LoopRun }).run;
}

async function waitTerminal(id: string): Promise<LoopRun> {
  await expect
    .poll(async () => (await getRun(id)).status, { timeout: 60_000, interval: 200 })
    .toSatisfy(isLoopRunTerminal);
  return getRun(id);
}

describe("loop run engine (real pi)", () => {
  it("completes after one iteration when validation passes (exit 0)", async () => {
    await putLoop("pass-loop", "exit 0", 5);
    const run = await waitTerminal(await startRun("pass-loop"));
    expect(run.status).toBe("completed");
    expect(run.stopReason).toBe("success");
    expect(run.iterations).toHaveLength(1);
    expect(run.iterations[0]).toMatchObject({ index: 1, validationPassed: true });
    // The agent actually ran (a real pi subagent produced output).
    expect(run.iterations[0]!.output.length).toBeGreaterThan(0);
  });

  it("runs every iteration then fails when validation never passes (exit 1)", async () => {
    await putLoop("fail-loop", "exit 1", 2);
    const run = await waitTerminal(await startRun("fail-loop"));
    expect(run.status).toBe("failed");
    expect(run.stopReason).toBe("validationFailedAfterFinalIteration");
    expect(run.iterations).toHaveLength(2);
    expect(run.iterations.every((i) => i.validationPassed === false)).toBe(true);
  });

  it("runs in an isolated git worktree (writeTarget newWorktree), keeping the branch", async () => {
    // A git repo project — `git worktree add` needs a repo with a branch.
    const gitProject = mkdtempSync(path.join(tmpdir(), "pi-loop-wt-"));
    const git = (args: string[]): void => void execFileSync("git", args, { cwd: gitProject });
    execFileSync("git", ["init", "-b", "main", gitProject]);
    git(["config", "user.email", "t@t.local"]);
    git(["config", "user.name", "T"]);
    writeFileSync(path.join(gitProject, "README.md"), "# x\n");
    git(["add", "-A"]);
    git(["commit", "-m", "init"]);
    const wtProjectId = (
      (await (
        await fetch(`${base}/projects`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ path: gitProject }),
        })
      ).json()) as { project: { id: string } }
    ).project.id;

    await fetch(`${base}/loops`, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        name: "wt-loop",
        goal: "Do the work.",
        validationCommand: "exit 0",
        maxIterations: 2,
        writeTarget: "newWorktree",
      }),
    });

    const runRes = await fetch(`${base}/loops/wt-loop/run`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        projectId: wtProjectId,
        provider: MOCK_PROVIDER_ID,
        model: MOCK_MODEL_ID,
        extensions: [process.env.AGENT_DECK_PROVIDER_EXTENSIONS],
        env: { HOME: tmpHome, USERPROFILE: tmpHome, PI_SKIP_VERSION_CHECK: "1" },
      }),
    });
    expect(runRes.status).toBe(201);
    const { run, worktree } = (await runRes.json()) as {
      run: LoopRun;
      worktree: { path: string; branch: string; sourceBranch: string } | null;
    };
    expect(worktree).toBeTruthy();
    expect(worktree!.branch).toMatch(/^agent-deck\/loop-/);
    expect(worktree!.sourceBranch).toBe("main");

    const final = await waitTerminal(run.id);
    expect(final.status).toBe("completed");

    // The branch is kept (committed work survives) and the worktree dir is gone.
    const branches = execFileSync("git", ["branch", "--list"], {
      cwd: gitProject,
      encoding: "utf8",
    });
    expect(branches).toContain(worktree!.branch);
    await expect.poll(() => existsSync(worktree!.path), { timeout: 15_000 }).toBe(false);
  });
});
