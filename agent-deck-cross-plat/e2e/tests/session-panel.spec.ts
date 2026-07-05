import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Phase-2 gate (native sidebar/session model): the pi agent is not a nav row,
 * and the sessions pull-up panel is one global expansion that persists while
 * you switch sessions — matching the Swift isCodingAgentPanelExpanded.
 */

let harness: E2eHarness;

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
});

test.afterAll(async () => {
  await harness.close();
});

test("no Pi Agent nav row — chat is reached through the sessions panel", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");
  // The removed nav button is gone; Projects/Agents/Skills remain.
  await expect(page.getByTestId("nav-chat")).toHaveCount(0);
  await expect(page.getByTestId("nav-projects")).toBeVisible();
});

test("the sessions panel stays expanded while switching sessions", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  // Two sessions so there's something to switch between.
  await page.getByTestId("composer-input").fill("first message");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("assistant-text")).toContainText("first message", {
    timeout: 30_000,
  });
  await page.getByTestId("new-chat").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  const panel = page.getByTestId("sessions-expanded");
  const rows = panel.locator('[data-testid^="chat-"][role="button"]');

  // Expand the panel.
  await page.getByTestId("sessions-expand").click();
  await expect(panel).toHaveAttribute("aria-hidden", "false");
  await expect(rows).toHaveCount(2);

  // Selecting a session inside the expanded panel must NOT collapse it.
  await rows.nth(1).click();
  await expect(panel).toHaveAttribute("aria-hidden", "false");
  await rows.nth(0).click();
  await expect(panel).toHaveAttribute("aria-hidden", "false");

  // The collapse chevron still collapses it.
  await page.getByTestId("sessions-collapse").click();
  await expect(panel).toHaveAttribute("aria-hidden", "true");
});

test("navigating to a nav section renders it with the panel collapsed", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  const panel = page.getByTestId("sessions-expanded");
  // Expand then collapse (nav is inert while the panel covers it), then a nav
  // pick both shows the section and leaves the panel down.
  await page.getByTestId("sessions-expand").click();
  await expect(panel).toHaveAttribute("aria-hidden", "false");
  await page.getByTestId("sessions-collapse").click();

  await page.getByTestId("nav-projects").click();
  await expect(page.getByTestId("projects-screen")).toBeVisible();
  await expect(panel).toHaveAttribute("aria-hidden", "true");
});
