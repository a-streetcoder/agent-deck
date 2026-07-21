import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, selectProject, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Slice 10 gate: the changed-files tree + diff panel against the REAL stack —
 * a real pi turn writes a file into a real git repo via its `write` tool, the
 * server's turn-boundary refresh pushes the changed set over `/rpc`, and the
 * web panel renders the tree, the per-file stats, and the file's unified diff.
 * A second turn writing another file updates the tree without user action.
 */

let harness: E2eHarness;
const repo = mkdtempSync(path.join(tmpdir(), "proj-diff-repo-"));

const FIRST_FILE = path.join(repo, "src", "feature.txt");
const SECOND_FILE = path.join(repo, "notes", "second.txt");
const FIRST_CONTENT = "alpha line\nbeta line\ngamma line\n";
const SECOND_CONTENT = "second file body\n";

test.beforeAll(async () => {
  const git = (args: string[]): void => {
    execFileSync("git", args, { cwd: repo, stdio: "ignore" });
  };
  git(["init", "-b", "main"]);
  git(["config", "user.email", "t@example.com"]);
  git(["config", "user.name", "Test"]);
  writeFileSync(path.join(repo, "README.md"), "# scratch\n");
  git(["add", "-A"]);
  git(["commit", "-m", "init"]);

  harness = await startHarness({
    chunkDelayMs: 20,
    reply: () => "Wrote the file for you.",
    // Each "write the … file" turn drives pi's real `write` tool exactly once:
    // once the tool RESULT for the current turn is back (a role:"tool" message
    // after the last user message), answer with text so the turn completes.
    toolCall: (lastUser, body) => {
      const lastUserIndex = body.messages.map((m) => m.role).lastIndexOf("user");
      const toolRanThisTurn = body.messages.slice(lastUserIndex + 1).some((m) => m.role === "tool");
      if (toolRanThisTurn) return null;
      if (lastUser.includes("first file")) {
        return { name: "write", arguments: { path: FIRST_FILE, content: FIRST_CONTENT } };
      }
      if (lastUser.includes("second file")) {
        return { name: "write", arguments: { path: SECOND_FILE, content: SECOND_CONTENT } };
      }
      return null;
    },
  });
  const response = await fetch(`${harness.baseUrl}/projects`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ path: repo }),
  });
  if (!response.ok) throw new Error(await response.text());
});

test.afterAll(async () => {
  await harness.close();
});

test("a turn's file write flows into the tree, the diff panel, and live updates", async ({
  page,
}) => {
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(repo));
  await expect(page.getByTestId("session-cwd")).toHaveText(repo);
  await page.getByTestId("new-chat").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  // The session's cwd is a git repo: the diff toggle appears once the
  // subscribe-time diff_files fetch answers repo:true — with no badge yet
  // (clean tree).
  const toggle = page.getByTestId("diff-toggle");
  await expect(toggle).toBeVisible();
  await expect(page.getByTestId("diff-badge")).toHaveCount(0);

  // Turn 1: pi writes the first file; the turn boundary pushes the new set
  // and the badge updates WITHOUT any user action.
  await page.getByTestId("composer-input").fill("please write the first file");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle", {
    timeout: 60_000,
  });
  await expect(page.getByTestId("diff-badge")).toHaveText("1", { timeout: 30_000 });

  // Open the panel: the tree groups the file under its directory with +3/-0.
  await toggle.click();
  const panel = page.getByTestId("diff-panel");
  await expect(panel).toBeVisible();
  await expect(page.getByTestId("diff-file-count")).toHaveText("1");
  const firstRow = page.locator('[data-testid="diff-tree-file"][data-path="src/feature.txt"]');
  await expect(firstRow).toBeVisible();
  await expect(firstRow).toHaveAttribute("data-status", "?"); // untracked
  await expect(firstRow.getByTestId("diff-stat")).toContainText("+3");
  await expect(page.getByTestId("diff-tree-dir")).toContainText("src");

  // Open the file's diff: the unified patch renders with its + lines.
  await firstRow.click();
  await expect(page.getByTestId("diff-file-view")).toBeVisible();
  await expect(page.getByTestId("diff-file-path")).toContainText("src/feature.txt");
  const addLines = page.locator('[data-testid="diff-line"][data-kind="add"]');
  await expect(addLines.first()).toBeVisible({ timeout: 15_000 });
  await expect(page.getByTestId("diff-lines")).toContainText("+alpha line");
  await expect(page.getByTestId("diff-lines")).toContainText("+gamma line");

  // Turn 2: another write updates the OPEN panel's tree + badge live.
  await page.getByTestId("composer-input").fill("now write the second file");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle", {
    timeout: 60_000,
  });
  await expect(page.getByTestId("diff-badge")).toHaveText("2", { timeout: 30_000 });
  await expect(page.getByTestId("diff-file-count")).toHaveText("2");
  await expect(
    page.locator('[data-testid="diff-tree-file"][data-path="notes/second.txt"]'),
  ).toBeVisible();
  // The first file's open diff survives the refresh.
  await expect(page.getByTestId("diff-lines")).toContainText("+alpha line");
});

test("the diff surface stays hidden for non-repo sessions", async ({ page }) => {
  await page.goto(harness.baseUrl);
  // The default (no-project) session runs in a non-git cwd: repo:false keeps
  // the toggle and panel hidden entirely.
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");
  await expect(page.getByTestId("composer-input")).toBeVisible();
  await expect(page.getByTestId("diff-toggle")).toHaveCount(0);
  await expect(page.getByTestId("diff-panel")).toHaveCount(0);
});
