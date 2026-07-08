import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Loop Bank (native LoopBankScreen, definition-CRUD slice): create, edit, and
 * delete a loop definition. The loop is persisted as ~/.pi/agent/loops/<slug>.loop.md.
 * The run engine is a later slice, so there's no launch here.
 */

let harness: E2eHarness;

function loopFile(): string {
  return path.join(harness.piHome, ".pi", "agent", "loops", "green-suite.loop.md");
}

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
});

test.afterAll(async () => {
  await harness.close();
});

test("creates, edits, and deletes a loop through the Bank", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-loops").click();
  await expect(page.getByTestId("loop-empty")).toBeVisible();

  // Create.
  await page.getByTestId("new-loop").click();
  await page.getByTestId("loop-name").fill("Green Suite");
  await page.getByTestId("loop-goal").fill("Make the test suite pass.");
  await page.getByTestId("loop-structure").selectOption("makerChecker");
  await page.getByTestId("loop-max-iterations").fill("6");
  await page.getByTestId("loop-validation").fill("pnpm test");
  await page.getByTestId("loop-save").click();

  const row = page.locator('[data-loop-name="Green Suite"]');
  await expect(row).toBeVisible();
  await expect(row).toContainText("Maker / checker");
  await expect(row).toContainText("6×");

  // Persisted to disk in the loops catalog.
  expect(existsSync(loopFile())).toBe(true);
  const raw = readFileSync(loopFile(), "utf8");
  expect(raw).toContain("name: Green Suite");
  expect(raw).toContain("maxIterations: 6");
  expect(raw).toContain("Make the test suite pass.");

  // Edit: reopen (name is fixed once created), bump iterations.
  await page.getByTestId("loop-open-Green Suite").click();
  await expect(page.getByTestId("loop-name")).toBeDisabled();
  await page.getByTestId("loop-max-iterations").fill("10");
  await page.getByTestId("loop-save").click();
  await expect(row).toContainText("10×");
  expect(readFileSync(loopFile(), "utf8")).toContain("maxIterations: 10");

  // Delete (confirm-gated).
  page.once("dialog", (dialog) => void dialog.accept());
  await page.getByTestId("loop-delete-Green Suite").click();
  await expect(row).toHaveCount(0);
  await expect(page.getByTestId("loop-empty")).toBeVisible();
  expect(existsSync(loopFile())).toBe(false);
});
