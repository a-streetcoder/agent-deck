import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Deck/plan progress ring (native PiAgentActivityPanelViews): the plan panel
 * header shows an animated SVG ring of done/total. Driven by the mock provider
 * making real pi call set_session_plan (2 items, 1 done → 50%).
 */

let harness: E2eHarness;

test.beforeAll(async () => {
  harness = await startHarness({
    chunkDelayMs: 20,
    reply: () => "Planned it out.",
    toolCall: (_lastUser, body) =>
      body.messages.some((m) => m.role === "tool")
        ? null
        : {
            name: "set_session_plan",
            arguments: {
              items: [
                { id: "a", title: "Write the tests", status: "done" },
                { id: "b", title: "Ship it", status: "in_progress" },
              ],
            },
          },
  });
});

test.afterAll(async () => {
  await harness.close();
});

test("the plan panel shows a progress ring reflecting done/total", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId("composer-input").fill("make a plan");
  await page.getByTestId("send-button").click();

  // The plan appears with 1 of 2 done → the ring reads 50%.
  await expect(page.getByTestId("session-plan")).toBeVisible({ timeout: 30_000 });
  await expect(page.getByTestId("plan-progress")).toHaveText("1/2");
  const ring = page.getByTestId("progress-ring");
  await expect(ring).toBeVisible();
  await expect(ring).toHaveAttribute("data-progress", "50");
});
