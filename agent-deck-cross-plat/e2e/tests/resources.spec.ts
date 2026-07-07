import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Slice-7 gate: the resource read path is live — builtin agents are listed,
 * scope filters work, and a file created ON DISK while the app is open shows
 * up via the watcher → resources_changed → refetch loop, no reload.
 */

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-res-"));

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
});

test.afterAll(async () => {
  await harness.close();
});

/** Register the project via REST (idempotent) so each test is self-contained. */
async function registerProject(): Promise<void> {
  const response = await fetch(`${harness.baseUrl}/projects`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ path: project }),
  });
  if (!response.ok) throw new Error(await response.text());
}

test("agents screen lists builtins and live-updates when files appear on disk", async ({
  page,
}) => {
  await registerProject();
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  await page.getByTestId(`project-${path.basename(project)}`).click();
  await expect(page.getByTestId("session-cwd")).toHaveText(project);

  await page.getByTestId("nav-agents").click();

  // Builtins are present.
  for (const name of ["coder", "explorer", "planner", "reviewer"]) {
    await expect(page.locator(`[data-agent-name="${name}"]`)).toBeVisible();
  }

  // Create a project agent ON DISK while the screen is open → live update.
  const agentsDir = path.join(project, ".pi", "agents");
  mkdirSync(agentsDir, { recursive: true });
  writeFileSync(
    path.join(agentsDir, "tester.md"),
    "---\nname: tester\ndescription: A live-created test agent\ntools: read, grep\n---\n\nYou are tester.\n",
  );
  const testerRow = page.locator('[data-agent-name="tester"]');
  await expect(testerRow).toBeVisible({ timeout: 15_000 });
  await expect(testerRow.getByTestId("scope-chip")).toHaveAttribute("data-scope", "project");

  // Scope filter: "project" shows only the new agent; builtins hidden.
  await page.getByTestId("agent-filter-project").click();
  await expect(page.getByTestId("agent-row")).toHaveCount(1);
  await page.getByTestId("agent-filter-builtin").click();
  await expect(page.locator('[data-agent-name="tester"]')).toHaveCount(0);

  // The "overridden" chip renders and filters: no builtin here carries a
  // settings.json override, so it lists nothing (the true-positive path is
  // unit + resources-integration tested).
  await page.getByTestId("agent-filter-overridden").click();
  await expect(page.getByTestId("agent-row")).toHaveCount(0);

  // Rename the project agent via the detail view: the file moves on disk and
  // the row follows the new name.
  await page.getByTestId("agent-filter-project").click();
  await page.locator('[data-agent-name="tester"]').click();
  await expect(page.getByTestId("agent-detail")).toBeVisible();
  await page.getByTestId("agent-rename").click();
  await page.getByTestId("agent-rename-input").fill("tester2");
  await page.getByTestId("agent-rename-confirm").click();

  await expect(page.locator('[data-agent-name="tester2"]')).toBeVisible({ timeout: 15_000 });
  await expect(page.locator('[data-agent-name="tester"]')).toHaveCount(0);
  const renamedFile = path.join(project, ".pi", "agents", "tester2.md");
  await expect.poll(() => existsSync(renamedFile)).toBe(true);
  expect(existsSync(path.join(project, ".pi", "agents", "tester.md"))).toBe(false);
});

test("skills screen live-updates when a SKILL.md appears on disk", async ({ page }) => {
  await registerProject();
  await page.goto(harness.baseUrl);
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await expect(page.getByTestId("session-cwd")).toHaveText(project);

  await page.getByTestId("nav-skills").click();

  const skillDir = path.join(project, ".pi", "skills", "release-notes");
  mkdirSync(skillDir, { recursive: true });
  writeFileSync(
    path.join(skillDir, "SKILL.md"),
    "---\nname: release-notes\ndescription: Draft release notes for this project\n---\n\nHow to draft.\n",
  );
  const row = page.locator('[data-skill-name="release-notes"]');
  await expect(row).toBeVisible({ timeout: 15_000 });
  await expect(row.getByTestId("scope-chip")).toHaveAttribute("data-scope", "project");

  // Rename the skill via the detail pane: the whole directory moves on disk.
  await row.click();
  await expect(page.getByTestId("skill-detail")).toBeVisible();
  await page.getByTestId("skill-rename").click();
  await page.getByTestId("skill-rename-input").fill("changelog");
  await page.getByTestId("skill-rename-confirm").click();

  await expect(page.locator('[data-skill-name="changelog"]')).toBeVisible({ timeout: 15_000 });
  await expect(page.locator('[data-skill-name="release-notes"]')).toHaveCount(0);
  const movedSkill = path.join(project, ".pi", "skills", "changelog", "SKILL.md");
  await expect.poll(() => existsSync(movedSkill)).toBe(true);
  expect(existsSync(path.join(project, ".pi", "skills", "release-notes"))).toBe(false);
});

test("multi-select bulk-deletes skills (7.5)", async ({ page }) => {
  await registerProject();
  await page.goto(harness.baseUrl);
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await page.getByTestId("nav-skills").click();

  // Two project skills on disk.
  for (const name of ["bulk-a", "bulk-b"]) {
    const dir = path.join(project, ".pi", "skills", name);
    mkdirSync(dir, { recursive: true });
    writeFileSync(
      path.join(dir, "SKILL.md"),
      `---\nname: ${name}\ndescription: A bulk-delete test skill\n---\n\nbody\n`,
    );
  }
  await expect(page.locator('[data-skill-name="bulk-a"]')).toBeVisible({ timeout: 15_000 });
  await expect(page.locator('[data-skill-name="bulk-b"]')).toBeVisible({ timeout: 15_000 });

  // Select both via the row checkboxes, then bulk delete.
  await page.getByTestId("skill-check-bulk-a").check();
  await page.getByTestId("skill-check-bulk-b").check();
  await expect(page.getByTestId("skills-bulk-bar")).toContainText("2 selected");
  await page.getByTestId("skills-bulk-delete").click();

  await expect(page.locator('[data-skill-name="bulk-a"]')).toHaveCount(0);
  await expect(page.locator('[data-skill-name="bulk-b"]')).toHaveCount(0);
  await expect(page.getByTestId("skills-bulk-bar")).toHaveCount(0);
  expect(existsSync(path.join(project, ".pi", "skills", "bulk-a"))).toBe(false);
  expect(existsSync(path.join(project, ".pi", "skills", "bulk-b"))).toBe(false);
});

test("imports a local .md file as a skill (7.3)", async ({ page }) => {
  await registerProject();
  await page.goto(harness.baseUrl);
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await page.getByTestId("nav-skills").click();

  // A source .md on disk (outside any catalog).
  const source = path.join(mkdtempSync(path.join(tmpdir(), "skill-src-")), "anything.md");
  writeFileSync(
    source,
    "---\nname: imported-skill\ndescription: An imported skill\n---\n\nDo the thing.\n",
  );

  await page.getByTestId("skill-import").click();
  await page.getByTestId("skill-import-path").fill(source);
  await page.getByTestId("skill-import-confirm").click();

  // The imported (global) skill appears, written into the global catalog.
  await expect(page.locator('[data-skill-name="imported-skill"]')).toBeVisible({ timeout: 15_000 });
  const imported = path.join(
    harness.piHome,
    ".pi",
    "agent",
    "skills",
    "imported-skill",
    "SKILL.md",
  );
  await expect.poll(() => existsSync(imported)).toBe(true);
  expect(readFileSync(imported, "utf8")).toContain("Do the thing.");
});
