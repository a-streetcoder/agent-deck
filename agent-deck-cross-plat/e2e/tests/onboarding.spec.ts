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

test("the first-run welcome shows and 'Add a project' opens Projects", async ({ page }) => {
  await page.goto(harness.baseUrl);
  const banner = page.getByTestId("onboarding");
  await expect(banner).toBeVisible();
  await expect(banner).toContainText("Welcome to Agent Deck");

  // 'Add a project' navigates to Projects but does NOT dismiss — it keeps
  // nudging until a project actually exists.
  await page.getByTestId("onboarding-add-project").click();
  await expect(page.getByTestId("projects-screen")).toBeVisible();
  await expect(banner).toBeVisible();
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
