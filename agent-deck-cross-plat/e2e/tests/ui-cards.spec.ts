import { expect, test } from "@playwright/test";
import { writeUiCardsExtension } from "@agent-deck/testkit";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Tier-4 gate (ask-user card types): the remaining extension_ui_request methods
 * — input (single line), select (options), and editor (multiline, prefilled) —
 * each render the right control and their answer flows back to pi. (confirm is
 * covered in polish.spec.)
 */

let harness: E2eHarness;

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20, extraExtensions: [writeUiCardsExtension()] });
});

test.afterAll(async () => {
  await harness.close();
});

async function runCommand(page: import("@playwright/test").Page, command: string): Promise<void> {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");
  // Fresh chat so each test's card is the only one in its transcript.
  await page.getByTestId("new-chat").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");
  await page.getByTestId("composer-input").fill(command);
  await page.getByTestId("send-button").click();
}

test("the input card takes a line and sends it back", async ({ page }) => {
  await runCommand(page, "/ask-input");
  const card = page.getByTestId("question-cell");
  await expect(card).toBeVisible({ timeout: 30_000 });
  await expect(card).toContainText("Your handle");
  await page.getByTestId("question-input").fill("moretti");
  await page.getByTestId("question-submit").click();
  await expect(card).toHaveAttribute("data-answered", "true");
});

test("the select card offers the options and sends the pick back", async ({ page }) => {
  await runCommand(page, "/ask-select");
  const card = page.getByTestId("question-cell");
  await expect(card).toBeVisible({ timeout: 30_000 });
  await expect(page.getByTestId("question-option-crimson")).toBeVisible();
  await page.getByTestId("question-option-viridian").click();
  await expect(card).toHaveAttribute("data-answered", "true");
});

test("the editor card is multiline and prefilled, and sends the edit back", async ({ page }) => {
  await runCommand(page, "/ask-editor");
  const card = page.getByTestId("question-cell");
  await expect(card).toBeVisible({ timeout: 30_000 });
  const editor = page.getByTestId("question-editor");
  await expect(editor).toBeVisible();
  await expect(editor).toHaveValue("hello from prefill");
  await editor.fill("hello from prefill\nand a second line");
  await page.getByTestId("question-submit").click();
  await expect(card).toHaveAttribute("data-answered", "true");
});
