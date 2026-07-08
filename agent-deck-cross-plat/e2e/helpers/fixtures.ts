import { test as base } from "@playwright/test";

/**
 * Shared e2e test with the first-run onboarding pre-dismissed. The onboarding is
 * a full-screen modal that shows while a user has no projects — which is the
 * default harness state — so without this it would cover the app and intercept
 * every click. The onboarding suite itself imports `test` from @playwright/test
 * directly so it still sees the modal.
 */
export const test = base.extend({
  page: async ({ page }, use) => {
    await page.addInitScript(() => {
      try {
        localStorage.setItem("agentdeck-onboarding-dismissed", "1");
      } catch {
        // Storage disabled — the test just sees the onboarding; harmless here.
      }
    });
    await use(page);
  },
});

export { expect } from "@playwright/test";
export type { Page } from "@playwright/test";
