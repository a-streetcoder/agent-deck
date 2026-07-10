import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "../helpers/fixtures.ts";
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

test("lists the imported repo, badges an upstream update, and pulls it", async ({ page }) => {
  // Import happened in the first test (shared harness). Fetch the repo id.
  const { repos } = (await (await fetch(`${harness.baseUrl}/resources/skill-repos`)).json()) as {
    repos: Array<{ id: string }>;
  };
  const id = repos[0]!.id;

  // Upstream advances.
  writeFileSync(
    path.join(sourceRepo, "web-scraper", "SKILL.md"),
    "---\nname: web-scraper\ndescription: Scrape web pages\n---\nHow to scrape MUCH faster.\n",
  );
  git(["commit", "-am", "faster"]);

  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-skills").click();

  // The repo is listed and the mount check badges it as updatable.
  await expect(page.getByTestId(`skill-repo-${id}`)).toBeVisible();
  await expect(page.getByTestId(`skill-repo-updatable-${id}`)).toBeVisible();

  // Update pulls the change; the badge clears and the catalog skill reflects it.
  await page.getByTestId(`skill-repo-update-${id}`).click();
  await expect(page.getByTestId(`skill-repo-updatable-${id}`)).toHaveCount(0);
  await expect
    .poll(async () => {
      const md = readFileSync(
        path.join(harness.piHome, ".pi", "agent", "skills", "web-scraper", "SKILL.md"),
        "utf8",
      );
      return md.includes("MUCH faster");
    })
    .toBe(true);
});

test("holds a locally-edited skill as a conflict and resolves it Take Remote", async ({ page }) => {
  const { repos } = (await (await fetch(`${harness.baseUrl}/resources/skill-repos`)).json()) as {
    repos: Array<{ id: string }>;
  };
  const id = repos[0]!.id;
  const skillMd = path.join(harness.piHome, ".pi", "agent", "skills", "web-scraper", "SKILL.md");

  // The user edits the catalog copy locally; upstream also changes it.
  writeFileSync(
    skillMd,
    "---\nname: web-scraper\ndescription: Scrape web pages\n---\nLOCAL EDIT.\n",
  );
  writeFileSync(
    path.join(sourceRepo, "web-scraper", "SKILL.md"),
    "---\nname: web-scraper\ndescription: Scrape web pages\n---\nUPSTREAM V3.\n",
  );
  git(["commit", "-am", "v3"]);

  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-skills").click();

  // Update holds the edit → a conflict block with Keep-Mine / Take-Remote.
  await page.getByTestId(`skill-repo-update-${id}`).click();
  await expect(page.getByTestId(`skill-repo-conflicts-${id}`)).toBeVisible();
  await expect(page.getByTestId(`skill-conflict-remote-${id}-web-scraper`)).toBeVisible();
  expect(readFileSync(skillMd, "utf8")).toContain("LOCAL EDIT"); // not overwritten

  // Take Remote → the upstream version wins and the conflict clears.
  await page.getByTestId(`skill-conflict-remote-${id}-web-scraper`).click();
  await expect(page.getByTestId(`skill-repo-conflicts-${id}`)).toHaveCount(0);
  await expect.poll(() => readFileSync(skillMd, "utf8").includes("UPSTREAM V3")).toBe(true);
});
