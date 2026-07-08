import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Stage-B gate (composer parity): the model chip reflects pi's live state,
 * the model menu lists pi's available models, and the thinking picker
 * round-trips through pi itself (verified via get_state).
 */

let harness: E2eHarness;

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
});

test.afterAll(async () => {
  await harness.close();
});

test("model chip shows pi's current model and lists available models", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  // Current model comes from pi get_state (the mock provider's model).
  await expect(page.getByTestId("model-chip-label")).toHaveText("mock-model");
  // The chip carries the provider's brand logo (the "mock" provider has no bundled mark → monogram fallback).
  await expect(page.getByTestId("model-chip").getByTestId("provider-logo-mock")).toBeVisible();

  await page.getByTestId("model-chip").click();
  await expect(page.getByTestId("model-menu")).toBeVisible();
  await expect(page.getByTestId("model-option-mock-model")).toBeVisible();
  await page.getByTestId("model-option-mock-model").click();
  await expect(page.getByTestId("model-menu")).toHaveCount(0);
});

test("thinking picker round-trips through pi", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  await page.getByTestId("thinking-chip").click();
  await page.getByTestId("thinking-option-high").click();
  await expect(page.getByTestId("thinking-chip-label")).toHaveText("high");

  // pi itself must report the new level.
  const sessionId = (await (await fetch(`${harness.baseUrl}/sessions`)).json()) as {
    sessions: Array<{ id: string; endedAt?: string }>;
  };
  const live = sessionId.sessions.filter((s) => !s.endedAt).at(-1)!;
  await expect
    .poll(async () => {
      const response = await fetch(`${harness.baseUrl}/sessions/${live.id}/state`);
      if (!response.ok) return "";
      const { state } = (await response.json()) as { state: { thinkingLevel: string } };
      return state.thinkingLevel;
    })
    .toBe("high");
});

test("thinking picker restricts a non-reasoning model to 'off' (native supportsThinking gate)", async ({
  page,
}) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  // The default model is reasoning-capable → the full ladder is offered.
  await page.getByTestId("thinking-chip").click();
  await expect(page.getByTestId("thinking-menu")).toBeVisible();
  await expect(page.getByTestId("thinking-option-high")).toBeVisible();

  // Switch to the non-reasoning "basic-model" (clicking the model chip also
  // dismisses the open thinking menu).
  await page.getByTestId("model-chip").click();
  await page.getByTestId("model-option-basic-model").click();
  await expect(page.getByTestId("model-chip-label")).toHaveText("basic-model");

  // Now the thinking picker offers only "off" — no reasoning levels.
  await page.getByTestId("thinking-chip").click();
  await expect(page.getByTestId("thinking-menu")).toBeVisible();
  await expect(page.getByTestId("thinking-option-off")).toBeVisible();
  await expect(page.getByTestId("thinking-option-high")).toHaveCount(0);
  await expect(page.getByTestId("thinking-option-minimal")).toHaveCount(0);
});
