import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, selectProject, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Session worktree isolation (native piAgentSessionsUseWorktree): with the
 * setting on, selecting a git-repo project starts the session in an isolated
 * worktree, and the Git screen offers a Merge action to bring the work back.
 */

let harness: E2eHarness;
const repo = mkdtempSync(path.join(tmpdir(), "wt-e2e-"));

function git(args: string[]): void {
  execFileSync("git", args, { cwd: repo, stdio: "ignore" });
}

test.beforeAll(async () => {
  git(["init", "-b", "main"]);
  git(["config", "user.email", "t@example.com"]);
  git(["config", "user.name", "Test"]);
  writeFileSync(path.join(repo, "README.md"), "# repo\n");
  git(["add", "-A"]);
  git(["commit", "-m", "init"]);
  harness = await startHarness({ chunkDelayMs: 20 });
});

test.afterAll(async () => {
  await harness.close();
});

test("an isolated session runs in a worktree and offers Merge on the Git screen", async ({
  page,
}) => {
  // Turn on worktree isolation and register the git repo, then select it — which
  // starts a session that (because the setting is on) runs in its own worktree.
  await fetch(`${harness.baseUrl}/settings`, {
    method: "PATCH",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ worktreeIsolation: true }),
  });
  const added = await fetch(`${harness.baseUrl}/projects`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ path: repo }),
  });
  expect(added.ok).toBe(true);

  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(repo));

  // The session's cwd is the isolated worktree, not the project root.
  await expect(page.getByTestId("session-cwd")).not.toHaveText(repo);

  // The Git screen surfaces the worktree + a Merge action back to `main`.
  await page.getByTestId("nav-git").click();
  await expect(page.getByTestId("git-worktree-banner")).toBeVisible();
  await expect(page.getByTestId("git-merge")).toContainText("Merge to main");
});
