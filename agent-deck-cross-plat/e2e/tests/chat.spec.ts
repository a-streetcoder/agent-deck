import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * The slice-5 gate, and attempt #1's exact failure as a permanent e2e test:
 * the transcript must GROW INCREMENTALLY in the DOM while pi streams — not
 * pop in whole after the reply finishes.
 */

const SCRIPTED_REPLY =
  "This reply streams across the wire one word at a time so the browser can render it incrementally";

let harness: E2eHarness;

test.beforeAll(async () => {
  harness = await startHarness({ reply: () => SCRIPTED_REPLY, chunkDelayMs: 120 });
});

test.afterAll(async () => {
  await harness.close();
});

test("chat renders the streamed reply incrementally", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  await page.getByTestId("composer-input").fill("hello there");
  await page.getByTestId("send-button").click();

  // User message appears immediately.
  await expect(page.getByTestId("user-cell")).toContainText("hello there");

  // Sample the assistant text while it streams: we must observe at least two
  // distinct, growing, non-empty partial lengths BEFORE the full text is shown.
  // Target the rendered markdown body inside the bubble (excludes the header).
  const assistantText = page.getByTestId("assistant-text").locator("[data-md-document-content]");
  const observedLengths: number[] = [];
  await expect
    .poll(
      async () => {
        const text = (await assistantText.textContent().catch(() => "")) ?? "";
        // Rendered markdown may carry block-level trailing whitespace.
        const length = text.trim().length;
        if (length > 0 && length !== observedLengths.at(-1)) observedLengths.push(length);
        const partials = observedLengths.filter((l) => l < SCRIPTED_REPLY.length);
        return partials.length >= 2 && observedLengths.at(-1) === SCRIPTED_REPLY.length;
      },
      { timeout: 60_000, intervals: [60] },
    )
    .toBe(true);

  // Growth was strictly monotonic (streaming, not re-rendering from scratch).
  expect(observedLengths).toEqual([...observedLengths].sort((a, b) => a - b));
  await expect(assistantText).toHaveText(SCRIPTED_REPLY);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");
});

test("shows the session context-usage indicator (native, from get_session_stats)", async ({
  page,
}) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  await page.getByTestId("composer-input").fill("hello there");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle", {
    timeout: 60_000,
  });

  // pi's get_session_stats reports a context-window fill (tokens / contextWindow),
  // so the composer shows a "% ctx" chip (percent is 0 for a tiny turn, not null).
  const chip = page.getByTestId("context-usage");
  await expect(chip).toBeVisible({ timeout: 15_000 });
  await expect(chip).toContainText("% ctx");
});

test("abort stops a streaming reply and returns to idle", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  await page.getByTestId("composer-input").fill("another question");
  await page.getByTestId("send-button").click();

  // While responding, the composer offers Stop; click it mid-stream.
  const abort = page.getByTestId("abort-button");
  await expect(abort).toBeVisible({ timeout: 30_000 });
  await abort.click();

  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle", {
    timeout: 30_000,
  });
  await expect(page.getByTestId("send-button")).toBeVisible();
});
