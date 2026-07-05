import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Tier-3 gate (Instructions screen): editing a project's AGENTS.md through the
 * screen writes pi's canonical project-context file to disk and reloads it.
 */

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-instructions-"));

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

test("the Default workspace prompts to pick a project", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-instructions").click();
  await expect(page.getByTestId("instructions-no-project")).toBeVisible();
});

test("editing a project's AGENTS.md writes it to disk and reloads", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await expect(page.getByTestId("session-cwd")).toHaveText(project);

  await page.getByTestId("nav-instructions").click();
  const editor = page.getByTestId("instructions-editor");
  await expect(editor).toBeVisible();
  await editor.fill("# House rules\n\nAlways write tidy commits.");
  await page.getByTestId("instructions-save").click();
  await expect(page.getByTestId("instructions-save")).toHaveText("Saved");

  // On disk where pi loads it.
  const file = path.join(project, "AGENTS.md");
  expect(existsSync(file)).toBe(true);
  expect(readFileSync(file, "utf8")).toContain("Always write tidy commits.");

  // And it reloads from disk on a fresh visit.
  await page.reload();
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await page.getByTestId("nav-instructions").click();
  await expect(page.getByTestId("instructions-editor")).toHaveValue(/Always write tidy commits\./);
});
