import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, selectProject, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Git screen (native GitRepositoryService, status + commit-all half): a real
 * temp git repo is the hermetic fixture — no network, deterministic. The screen
 * lists the working-tree changes and commits them.
 */

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-git-"));

function git(args: string[]): string {
  return execFileSync("git", args, { cwd: project, encoding: "utf8" });
}

test.beforeAll(async () => {
  // A real repo with an initial commit, then an uncommitted new file.
  execFileSync("git", ["init", "-b", "main", project], { encoding: "utf8" });
  git(["config", "user.email", "test@agent-deck.local"]);
  git(["config", "user.name", "Agent Deck Test"]);
  writeFileSync(path.join(project, "README.md"), "# project\n");
  git(["add", "-A"]);
  git(["commit", "-m", "initial commit"]);
  writeFileSync(path.join(project, "feature.ts"), "export const x = 1;\n");

  harness = await startHarness({ chunkDelayMs: 20 });
  const response = await fetch(`${harness.baseUrl}/projects`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ path: project }),
  });
  if (!response.ok) throw new Error(await response.text());
});

test.afterAll(async () => {
  await harness.close();
});

test("shows working-tree changes and commits them", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(project));
  await expect(page.getByTestId("session-cwd")).toHaveText(project);

  await page.getByTestId("nav-git").click();
  // The branch and the uncommitted new file are surfaced.
  await expect(page.getByTestId("git-branch")).toHaveText("main");
  await expect(page.locator('[data-git-path="feature.ts"]')).toBeVisible();

  // Commit is gated on a message.
  const commitButton = page.getByTestId("git-commit");
  await expect(commitButton).toBeDisabled();
  await page.getByTestId("git-commit-message").fill("Add feature.ts");
  await expect(commitButton).toBeEnabled();
  await commitButton.click();

  // A success toast confirms the commit, then auto-dismisses.
  const toast = page.getByTestId("toast");
  await expect(toast).toHaveText(/Committed/);
  await expect(toast).toHaveAttribute("data-kind", "success");
  await expect(toast).toHaveCount(0, { timeout: 6_000 }); // auto-dismissed

  // The working tree goes clean and the file leaves the list.
  await expect(page.getByTestId("git-clean")).toBeVisible();
  await expect(page.locator('[data-git-path="feature.ts"]')).toHaveCount(0);

  // The commit really landed in the repo.
  expect(git(["log", "--oneline"])).toContain("Add feature.ts");
  expect(git(["status", "--porcelain"]).trim()).toBe("");
});

test("rejects an empty commit and reports it", async () => {
  // Nothing left to commit after the previous test.
  const response = await fetch(`${harness.baseUrl}/projects`);
  const { projects } = (await response.json()) as { projects: Array<{ id: string; path: string }> };
  const id = projects.find((p) => p.path === project)!.id;
  const commit = await fetch(`${harness.baseUrl}/projects/${id}/git/commit`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ message: "nothing here" }),
  });
  expect(commit.status).toBe(400);
  expect(await commit.text()).toContain("no changes to commit");
});

test("git-automation setting gates the commit/push actions (native piAgentGitAutomationEnabled)", async ({
  page,
}) => {
  const settings = `${harness.baseUrl}/settings`;
  const setGit = (on: boolean) =>
    fetch(settings, {
      method: "PATCH",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ gitAutomation: on }),
    });

  // Off → the screen becomes a read-only status view (no commit box).
  await setGit(false);
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(project));
  await page.getByTestId("nav-git").click();
  await expect(page.getByTestId("git-actions-off")).toBeVisible();
  await expect(page.getByTestId("git-commit-message")).toHaveCount(0);

  // On → the commit action returns. Restored on so the setting is left enabled.
  await setGit(true);
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(project));
  await page.getByTestId("nav-git").click();
  await expect(page.getByTestId("git-commit-message")).toBeVisible();
});
