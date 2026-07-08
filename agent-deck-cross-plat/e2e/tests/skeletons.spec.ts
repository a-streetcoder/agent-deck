import { expect, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Loading skeletons: a resource list shows pulse placeholders while its FIRST
 * fetch is in flight, then swaps to the data (or empty state) — never flashing
 * the empty state first. The /loops fetch is delayed so the skeleton is stable.
 */

let harness: E2eHarness;

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
});

test.afterAll(async () => {
  await harness.close();
});

test("the Loop Bank shows a skeleton while loading, then the empty state", async ({ page }) => {
  // Delay the loops fetch so the skeleton stays up long enough to observe.
  await page.route("**/loops", async (route) => {
    await new Promise((resolve) => setTimeout(resolve, 1200));
    await route.continue();
  });

  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-loops").click();

  // Skeleton is up while the (delayed) fetch is in flight; the empty state is NOT.
  await expect(page.getByTestId("skeleton")).toBeVisible();
  await expect(page.getByTestId("loop-empty")).toHaveCount(0);

  // Once the fetch settles, the skeleton is replaced by the real empty state.
  await expect(page.getByTestId("loop-empty")).toBeVisible({ timeout: 10_000 });
  await expect(page.getByTestId("skeleton")).toHaveCount(0);
});
