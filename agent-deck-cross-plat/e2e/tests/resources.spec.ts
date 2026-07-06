import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
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
});
