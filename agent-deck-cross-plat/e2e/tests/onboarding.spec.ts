import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Onboarding (native WelcomeOnboardingSheet): a phased first-run flow — the
 * illustrated tour, then a functional Setup Check (the /runtime/doctor
 * dependency probe), then a Final step that smart-routes to whatever still
 * needs attention. Shows while the user has no projects; auto-hides once one
 * exists. The onboarding suite imports `test` from @playwright/test directly
 * (no fixtures pre-dismiss), so it sees the modal.
 */

let harness: E2eHarness;

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
});

test.afterAll(async () => {
  await harness.close();
});

test("walks the tour, runs the setup check, and finishes from the final step", async ({ page }) => {
  await page.goto(harness.baseUrl);
  const overlay = page.getByTestId("onboarding");
  await expect(overlay).toBeVisible();

  // Tour: the native illustration + title, advancing through the pages.
  await expect(page.getByTestId("onboarding-image")).toBeVisible();
  await expect(page.getByTestId("onboarding-title")).toHaveText("Command Pi from Agent Deck");
  await page.getByTestId("onboarding-next").click();
  await expect(page.getByTestId("onboarding-title")).toHaveText("Work in a Coding Chat");
  for (let i = 0; i < 4; i += 1) await page.getByTestId("onboarding-next").click();
  await expect(page.getByTestId("onboarding-title")).toHaveText("Connect the Wider Workflow");

  // The last tour page's CTA is "Check Setup" (not a project add), which opens
  // the functional Setup Check step.
  await expect(page.getByTestId("onboarding-next")).toHaveCount(0);
  await page.getByTestId("onboarding-check-setup").click();

  // Setup Check: the doctor probe renders real checks, including the pi runtime.
  await expect(page.getByTestId("onboarding-setup")).toBeVisible();
  const piCheck = page.locator('[data-check-id="pi-binary"]');
  await expect(piCheck).toBeVisible();
  // pi is installed in the e2e environment, so it reads Ready. The doctor
  // probes real subprocesses and can take 4-10s under full-suite load — same
  // headroom precedent as the doctor unit tests.
  await expect(piCheck).toHaveAttribute("data-check-status", "ok", { timeout: 20_000 });

  // Preferences: native OnboardingPreferences toggles/pickers that persist to
  // /settings. autoTitle defaults on; toggling it off writes through.
  await page.getByTestId("onboarding-setup-continue").click();
  await expect(page.getByTestId("onboarding-preferences")).toBeVisible();
  const autoTitle = page.getByTestId("pref-auto-title");
  await expect(autoTitle).toHaveAttribute("aria-checked", "true");
  await autoTitle.click();
  await expect(autoTitle).toHaveAttribute("aria-checked", "false");
  await expect
    .poll(async () => {
      const settings = (await (await fetch(`${harness.baseUrl}/settings`)).json()) as {
        settings: { autoTitle: boolean };
      };
      return settings.settings.autoTitle;
    })
    .toBe(false);

  // Continue to the Final step, which surfaces a smart-routed primary action.
  await page.getByTestId("onboarding-preferences-continue").click();
  await expect(page.getByTestId("onboarding-final")).toBeVisible();
  const finish = page.getByTestId("onboarding-finish");
  await expect(finish).toBeVisible();
  // The routing target is one of the known views (varies with the environment's
  // provider/project state); finishing dismisses the overlay.
  const target = await finish.getAttribute("data-target");
  expect(["chat", "doctor", "providers", "projects"]).toContain(target);
  await finish.click();
  await expect(overlay).toBeHidden();
});

test("Skip dismisses the welcome and it stays dismissed across reloads", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("onboarding")).toBeVisible();
  await page.getByTestId("onboarding-skip").click();
  await expect(page.getByTestId("onboarding")).toBeHidden();
  await page.reload();
  await expect(page.getByTestId("onboarding")).toBeHidden();
});

test("the welcome auto-hides once a project exists", async ({ page }) => {
  const project = mkdtempSync(path.join(tmpdir(), "proj-onboarding-"));
  const response = await fetch(`${harness.baseUrl}/projects`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ path: project }),
  });
  expect(response.ok).toBe(true);

  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("onboarding")).toBeHidden();
});
