import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Tier-3 gate (Models screen): the provider/model catalog pi offers for the
 * current session renders grouped with metadata, and the active model is
 * marked. The mock provider registers one reasoning-capable model.
 */

let harness: E2eHarness;

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
});

test.afterAll(async () => {
  await harness.close();
});

test("the Models screen lists the provider catalog and marks the active model", async ({
  page,
}) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  // Send a message so a session exists with a resolved model.
  await page.getByTestId("composer-input").fill("hi");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("assistant-text")).toContainText("hi", { timeout: 30_000 });

  await page.getByTestId("nav-models").click();
  await expect(page.getByTestId("models-screen")).toBeVisible();

  const model = page.getByTestId("model-mock-model");
  await expect(model).toBeVisible();
  await expect(model).toContainText("Mock Model");
  await expect(model.getByTestId("reasoning-badge")).toBeVisible();
  await expect(model).toContainText("128K ctx");
  // Max output tokens badge (native model row "ctx … · out …"): mock model is 4096.
  await expect(model).toContainText("4K out");
  // It's the session's active model.
  await expect(model).toHaveAttribute("data-active", "true");
});

test("the Models catalog search filters by name/id/provider", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");
  await page.getByTestId("composer-input").fill("hi");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("assistant-text")).toContainText("hi", { timeout: 30_000 });
  await page.getByTestId("nav-models").click();

  const model = page.getByTestId("model-mock-model");
  await expect(model).toBeVisible();

  // A matching query keeps the model; a non-match shows the empty state.
  await page.getByTestId("models-search").fill("mock");
  await expect(model).toBeVisible();
  await page.getByTestId("models-search").fill("nonexistent-xyz");
  await expect(model).toHaveCount(0);
  await expect(page.getByTestId("models-search-empty")).toBeVisible();

  // Clearing restores it.
  await page.getByTestId("models-search").fill("");
  await expect(model).toBeVisible();
});
