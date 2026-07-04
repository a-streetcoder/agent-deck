import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Stage-F gate (runtime screens): the Environment inspector shows masked
 * .env values with scope + override flags, and Doctor reports a healthy pi
 * binary (the harness resolves the real pi) with version.
 */

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-runtime-"));

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
  mkdirSync(path.join(harness.piHome, ".pi", "agent"), { recursive: true });
  writeFileSync(
    path.join(harness.piHome, ".pi", "agent", ".env"),
    "OPENAI_API_KEY=sk-secret-value-1234\nSHARED_KEY=global-value\n",
  );
  mkdirSync(path.join(project, ".pi"), { recursive: true });
  writeFileSync(path.join(project, ".pi", ".env"), "SHARED_KEY=project-value\n");

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

test("environment inspector masks values and flags overrides", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await expect(page.getByTestId("session-cwd")).toHaveText(project);

  await page.getByTestId("nav-environment").click();

  const apiKeyRow = page.locator('[data-env-key="OPENAI_API_KEY"]');
  await expect(apiKeyRow).toBeVisible();
  // The full secret is never rendered — only a masked tail.
  await expect(apiKeyRow).not.toContainText("sk-secret-value-1234");
  await expect(apiKeyRow).toContainText("1234");

  // SHARED_KEY exists globally (overridden) and in the project.
  const sharedRows = page.locator('[data-env-key="SHARED_KEY"]');
  await expect(sharedRows).toHaveCount(2);
});

test("doctor reports a healthy pi binary with a version", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-doctor").click();

  const binCheck = page.locator('[data-check-id="pi-binary"]');
  await expect(binCheck).toBeVisible();
  await expect(binCheck).toHaveAttribute("data-check-status", "ok");

  const versionCheck = page.locator('[data-check-id="pi-version"]');
  await expect(versionCheck).toHaveAttribute("data-check-status", "ok");
  await expect(versionCheck).toContainText("0.80.3");

  // Re-check button works.
  await page.getByTestId("doctor-refresh").click();
  await expect(page.locator('[data-check-id="pi-binary"]')).toBeVisible();
});
