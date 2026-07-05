import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Stage-I gate (editable Environment): add, edit, and delete .env keys from
 * the UI, writing the real files with masked display and no secret leakage.
 */

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-env-"));

function globalEnvPath(): string {
  return path.join(harness.piHome, ".pi", "agent", ".env");
}
function projectEnvPath(): string {
  return path.join(project, ".pi", ".env");
}

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
  mkdirSync(path.join(harness.piHome, ".pi", "agent"), { recursive: true });
  writeFileSync(globalEnvPath(), "# my keys\nEXISTING_KEY=old-value\n");
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

test("add a global env var — written to the real file, shown masked", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-environment").click();

  await page.getByTestId("env-add").click();
  await page.getByTestId("env-new-key").fill("NEW_TOKEN");
  await page.getByTestId("env-new-value").fill("super-secret-value-9999");
  await page.getByTestId("env-new-save").click();

  const row = page.locator('[data-env-key="NEW_TOKEN"]');
  await expect(row).toBeVisible();
  await expect(row).not.toContainText("super-secret-value-9999"); // masked
  await expect(row).toContainText("9999");

  // The real file has the value, and the pre-existing comment survives.
  const content = readFileSync(globalEnvPath(), "utf8");
  expect(content).toContain("NEW_TOKEN=super-secret-value-9999");
  expect(content).toContain("# my keys");
  expect(content).toContain("EXISTING_KEY=old-value");
});

test("edit an existing var replaces its value, preserving other lines", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-environment").click();

  await page.getByTestId("env-edit-EXISTING_KEY").click();
  const input = page.getByTestId("env-edit-input-EXISTING_KEY");
  await input.fill("brand-new-value");
  await input.press("Enter");

  await expect
    .poll(() => readFileSync(globalEnvPath(), "utf8"))
    .toContain("EXISTING_KEY=brand-new-value");
  expect(readFileSync(globalEnvPath(), "utf8")).not.toContain("old-value");
  // Untouched keys and comments remain.
  expect(readFileSync(globalEnvPath(), "utf8")).toContain("# my keys");
});

test("delete a var removes it from the file", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-environment").click();

  await page.getByTestId("env-delete-NEW_TOKEN").click();
  await expect(page.locator('[data-env-key="NEW_TOKEN"]')).toHaveCount(0);
  expect(readFileSync(globalEnvPath(), "utf8")).not.toContain("NEW_TOKEN");
});

test("a project-scoped var writes to the project .env", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  await page.getByTestId("nav-environment").click();

  await page.getByTestId("env-add").click();
  await page.getByTestId("env-new-key").fill("PROJECT_ONLY");
  await page.getByTestId("env-new-value").fill("pv");
  await page.getByTestId("env-new-scope").selectOption("project");
  await page.getByTestId("env-new-save").click();

  await expect(page.locator('[data-env-key="PROJECT_ONLY"]')).toBeVisible();
  expect(existsSync(projectEnvPath())).toBe(true);
  expect(readFileSync(projectEnvPath(), "utf8")).toContain("PROJECT_ONLY=pv");
});
