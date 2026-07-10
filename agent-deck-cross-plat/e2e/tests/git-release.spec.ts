import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, selectProject, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Release (native ReleaseService, generalized to any repo): the Git screen's
 * Release panel proposes the next version off the latest tag, drafts notes from
 * commits via the mock provider, and tags + pushes to a hermetic bare origin.
 */

let harness: E2eHarness;
const bare = mkdtempSync(path.join(tmpdir(), "rel-bare-"));
const work = mkdtempSync(path.join(tmpdir(), "rel-work-"));

function gitIn(cwd: string, args: string[]): string {
  return execFileSync("git", args, { cwd, encoding: "utf8" });
}

test.beforeAll(async () => {
  execFileSync("git", ["init", "--bare", bare], { encoding: "utf8" });
  execFileSync("git", ["init", "-b", "main", work], { encoding: "utf8" });
  gitIn(work, ["config", "user.email", "test@agent-deck.local"]);
  gitIn(work, ["config", "user.name", "Agent Deck Test"]);
  gitIn(work, ["remote", "add", "origin", bare]);
  writeFileSync(path.join(work, "README.md"), "# app\n");
  gitIn(work, ["add", "-A"]);
  gitIn(work, ["commit", "-m", "initial"]);
  gitIn(work, ["tag", "v1.0.0"]);
  gitIn(work, ["push", "origin", "main"]);
  gitIn(work, ["push", "origin", "v1.0.0"]);
  // A commit after the tag so there is something to release.
  writeFileSync(path.join(work, "export.ts"), "export const x = 1;\n");
  gitIn(work, ["add", "-A"]);
  gitIn(work, ["commit", "-m", "add export feature"]);
  gitIn(work, ["push", "origin", "main"]);

  harness = await startHarness({
    chunkDelayMs: 20,
    reply: () => "### ✨ New features\n- Add an export feature",
  });
  const res = await fetch(`${harness.baseUrl}/projects`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ path: work }),
  });
  if (!res.ok) throw new Error(await res.text());
});

test.afterAll(async () => {
  await harness.close();
});

test("Release proposes the next version, drafts notes, and tags the origin", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(work));
  await expect(page.getByTestId("session-cwd")).toHaveText(work);
  await page.getByTestId("nav-git").click();

  await page.getByTestId("git-release").click();
  // Preflight proposed the next patch off v1.0.0.
  await expect(page.getByTestId("git-release-version-patch")).toContainText("v1.0.1");
  await expect(page.getByTestId("git-release-version-minor")).toContainText("v1.1.0");

  // Pick a minor bump and draft notes from the commits since the tag.
  await page.getByTestId("git-release-version-minor").click();
  await page.getByTestId("git-release-generate").click();
  await expect(page.getByTestId("git-release-notes")).toHaveValue(/New features/, {
    timeout: 15_000,
  });

  await page.getByTestId("git-release-confirm").click();

  // The annotated tag reached the bare origin.
  await expect.poll(() => gitIn(bare, ["tag", "-l"])).toContain("v1.1.0");
});
