import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Git push (native pushCurrentBranch): a local bare repo is the hermetic origin
 * — `git push` to a filesystem remote needs no network. The work repo's branch
 * has NO upstream, so Commit & Push exercises the `-u origin <branch>` fallback.
 */

let harness: E2eHarness;
const bare = mkdtempSync(path.join(tmpdir(), "git-bare-"));
const work = mkdtempSync(path.join(tmpdir(), "git-work-"));
const noRemote = mkdtempSync(path.join(tmpdir(), "git-noremote-"));

function gitIn(cwd: string, args: string[]): string {
  return execFileSync("git", args, { cwd, encoding: "utf8" });
}

test.beforeAll(async () => {
  execFileSync("git", ["init", "--bare", bare], { encoding: "utf8" });

  // A work repo pointed at the bare origin, but its branch is never pushed — so
  // `git push` will fail on a missing upstream and fall back to -u.
  execFileSync("git", ["init", "-b", "main", work], { encoding: "utf8" });
  gitIn(work, ["config", "user.email", "test@agent-deck.local"]);
  gitIn(work, ["config", "user.name", "Agent Deck Test"]);
  gitIn(work, ["remote", "add", "origin", bare]);
  writeFileSync(path.join(work, "README.md"), "# work\n");
  gitIn(work, ["add", "-A"]);
  gitIn(work, ["commit", "-m", "initial"]);
  writeFileSync(path.join(work, "feature.ts"), "export const x = 1;\n");

  // A repo with no remote at all — push must fail cleanly.
  execFileSync("git", ["init", "-b", "main", noRemote], { encoding: "utf8" });
  gitIn(noRemote, ["config", "user.email", "t@t.local"]);
  gitIn(noRemote, ["config", "user.name", "T"]);
  writeFileSync(path.join(noRemote, "a.txt"), "a\n");
  gitIn(noRemote, ["add", "-A"]);
  gitIn(noRemote, ["commit", "-m", "init"]);

  harness = await startHarness({ chunkDelayMs: 20 });
  for (const p of [work, noRemote]) {
    const res = await fetch(`${harness.baseUrl}/projects`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path: p }),
    });
    if (!res.ok) throw new Error(await res.text());
  }
});

test.afterAll(async () => {
  await harness.close();
});

test("Commit & Push publishes to the remote via the -u upstream fallback", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId(`project-${path.basename(work)}`).click();
  await expect(page.getByTestId("session-cwd")).toHaveText(work);
  await page.getByTestId("nav-git").click();

  await expect(page.locator('[data-git-path="feature.ts"]')).toBeVisible();
  await page.getByTestId("git-commit-message").fill("Add feature via push");
  await page.getByTestId("git-commit-push").click();

  // The tree goes clean locally…
  await expect(page.getByTestId("git-clean")).toBeVisible();
  // …and the commit reached the bare origin's main branch.
  await expect
    .poll(() => gitIn(bare, ["log", "--oneline", "main"]))
    .toContain("Add feature via push");
});

test("push with no remote fails cleanly (502)", async () => {
  const res = await fetch(`${harness.baseUrl}/projects`);
  const { projects } = (await res.json()) as { projects: Array<{ id: string; path: string }> };
  const id = projects.find((p) => p.path === noRemote)!.id;
  const push = await fetch(`${harness.baseUrl}/projects/${id}/git/push`, { method: "POST" });
  expect(push.status).toBe(502);
  expect(await push.text()).toContain("Push failed");
});
