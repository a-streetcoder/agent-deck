import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Tier-5 gate (onboarding): a first-run welcome banner shows while the user has
 * no projects, guides them to add one, and auto-hides once a project exists.
 * Kept non-blocking, so it never covers the composer or nav.
 */

let harness: E2eHarness;

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
});

test.afterAll(async () => {
  await harness.close();
});

test("the paged illustrated welcome advances and its final CTA opens Projects", async ({
  page,
}) => {
  await page.goto(harness.baseUrl);
  const overlay = page.getByTestId("onboarding");
  await expect(overlay).toBeVisible();
  // Page 1: the native illustration + title render.
  await expect(page.getByTestId("onboarding-image")).toBeVisible();
  await expect(page.getByTestId("onboarding-title")).toHaveText("Command Pi from Agent Deck");

  // Continue advances the pages; the title changes.
  await page.getByTestId("onboarding-next").click();
  await expect(page.getByTestId("onboarding-title")).toHaveText("Work in a Coding Chat");

  // Page through to the last page — only there does the primary CTA become
  // 'Add a project', which opens Projects and completes onboarding.
  for (let i = 0; i < 4; i += 1) await page.getByTestId("onboarding-next").click();
  await expect(page.getByTestId("onboarding-title")).toHaveText("Connect the Wider Workflow");
  await expect(page.getByTestId("onboarding-next")).toHaveCount(0);
  await page.getByTestId("onboarding-add-project").click();
  await expect(page.getByTestId("projects-screen")).toBeVisible();
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
