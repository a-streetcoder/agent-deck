import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Keyboard shortcuts (native AgentDeckCommands.swift), dispatched in-app. Driven
 * with Playwright's cross-platform `ControlOrMeta` so the same spec exercises
 * Ctrl on the Linux/Windows CI legs and ⌘ on a local macOS run.
 */

let harness: E2eHarness;

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
});

test.afterAll(async () => {
  await harness.close();
});

test("⌘1–6 jump between screens and ⌘1 returns to chat", async ({ page }) => {
  await page.goto(harness.baseUrl);
  const title = page.getByTestId("app-view-title");
  const chat = page.getByTestId("chat-layer");

  await page.keyboard.press("ControlOrMeta+4");
  await expect(title).toHaveText("Agents");
  await page.keyboard.press("ControlOrMeta+5");
  await expect(title).toHaveText("Skills");
  await page.keyboard.press("ControlOrMeta+2");
  await expect(title).toHaveText("Projects");
  await page.keyboard.press("ControlOrMeta+3");
  await expect(title).toHaveText("Issues");
  await page.keyboard.press("ControlOrMeta+6");
  await expect(title).toHaveText("Prompts");

  // ⌘1 returns to the always-mounted chat surface (un-hidden).
  await page.keyboard.press("ControlOrMeta+1");
  await expect(chat).toHaveAttribute("aria-hidden", "false");
});

test("the modifier is required — a bare digit never navigates", async ({ page }) => {
  await page.goto(harness.baseUrl);
  const title = page.getByTestId("app-view-title");

  await page.keyboard.press("ControlOrMeta+4");
  await expect(title).toHaveText("Agents");
  // A bare "1" (no Ctrl/⌘) must not steal focus back to chat.
  await page.keyboard.press("1");
  await expect(title).toHaveText("Agents");
});

test("⌘N starts a new session on the chat surface", async ({ page }) => {
  await page.goto(harness.baseUrl);
  // Leave chat first so we can prove the shortcut brings us back.
  await page.keyboard.press("ControlOrMeta+5");
  await expect(page.getByTestId("app-view-title")).toHaveText("Skills");

  await page.keyboard.press("ControlOrMeta+n");
  await expect(page.getByTestId("chat-layer")).toHaveAttribute("aria-hidden", "false");
  await expect(page.getByTestId("session-cwd")).toBeVisible();
});
