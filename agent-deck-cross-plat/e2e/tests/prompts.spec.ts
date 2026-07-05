import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Tier-3 gate (Prompts screen): a prompt template created through the screen
 * lands on disk as a .pi/prompts/<name>.md file (pi's /prompt:<name>), edits
 * persist, and delete removes it.
 */

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-prompts-"));

test.beforeAll(async () => {
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

test("create, edit, and delete a project prompt template", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  await page.getByTestId("nav-prompts").click();

  // Create.
  await page.getByTestId("prompt-new").click();
  await page.getByTestId("prompt-name").fill("review");
  await page.getByTestId("prompt-description").fill("Review this change");
  await page.getByTestId("prompt-body").fill("Please review the diff for bugs.");
  await page.getByTestId("prompt-save").click();

  const row = page.locator('[data-prompt-name="review"]');
  await expect(row).toBeVisible();
  await expect(row).toContainText("/prompt:review");
  await expect(row.getByTestId("scope-chip")).toHaveAttribute("data-scope", "project");

  // On disk where pi loads it.
  const file = path.join(project, ".pi", "prompts", "review.md");
  expect(existsSync(file)).toBe(true);
  expect(readFileSync(file, "utf8")).toContain("Please review the diff for bugs.");

  // Edit the body.
  await row.getByText("/prompt:review").click();
  await page.getByTestId("prompt-body").fill("Please review the diff for security issues.");
  await page.getByTestId("prompt-save").click();
  await expect
    .poll(() => readFileSync(file, "utf8"))
    .toContain("Please review the diff for security issues.");

  // Delete.
  await page.getByTestId("prompt-delete-review").click();
  await expect(page.locator('[data-prompt-name="review"]')).toHaveCount(0);
  expect(existsSync(file)).toBe(false);
});
