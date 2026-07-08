import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Skills git-import (native SkillRepositorySync, import half): a real local git
 * repo is the hermetic fixture — `git clone` accepts a filesystem path, so the
 * whole flow runs with no network. The repo holds a skill in a subdirectory.
 */

let harness: E2eHarness;
const sourceRepo = path.join(tmpdir(), `skillsrc-${path.basename(tmpdir())}-${Date.now()}`);

function git(args: string[]): void {
  execFileSync("git", args, { cwd: sourceRepo, encoding: "utf8" });
}

test.beforeAll(async () => {
  // A committed source repo with one skill under web-scraper/.
  mkdirSync(path.join(sourceRepo, "web-scraper"), { recursive: true });
  writeFileSync(
    path.join(sourceRepo, "web-scraper", "SKILL.md"),
    "---\nname: web-scraper\ndescription: Scrape web pages\n---\nHow to scrape.\n",
  );
  writeFileSync(path.join(sourceRepo, "web-scraper", "helper.py"), "print('hi')\n");
  execFileSync("git", ["init", "-b", "main", sourceRepo], { encoding: "utf8" });
  git(["config", "user.email", "test@agent-deck.local"]);
  git(["config", "user.name", "Agent Deck Test"]);
  git(["add", "-A"]);
  git(["commit", "-m", "add web-scraper skill"]);

  harness = await startHarness({ chunkDelayMs: 20 });
});

test.afterAll(async () => {
  await harness.close();
});

test("imports a skill from a git repository and it lands in the catalog", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-skills").click();

  // Open the git-import input and clone from the local repo path (no network).
  await page.getByTestId("skill-import-git").click();
  await page.getByTestId("skill-import-git-url").fill(sourceRepo);
  await page.getByTestId("skill-import-git-confirm").click();

  // The imported skill appears in the list…
  await expect(page.locator('[data-skill-name="web-scraper"]')).toBeVisible();

  // …and its whole directory (SKILL.md + asset) is copied into the global catalog.
  const dest = path.join(harness.piHome, ".pi", "agent", "skills", "web-scraper");
  expect(existsSync(path.join(dest, "SKILL.md"))).toBe(true);
  expect(existsSync(path.join(dest, "helper.py"))).toBe(true);
  expect(readFileSync(path.join(dest, "SKILL.md"), "utf8")).toContain("Scrape web pages");
});

test("a bad repo URL reports a clone error", async () => {
  const res = await fetch(`${harness.baseUrl}/resources/skills/import-git`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ scope: "global", url: path.join(tmpdir(), "does-not-exist-repo") }),
  });
  expect(res.status).toBe(400);
  expect(await res.text()).toContain("clone");
});
