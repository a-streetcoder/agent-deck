import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "@playwright/test";
import type { SessionMeta } from "@agent-deck/domain";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Slice-6 gate: switching project creates/uses a session whose pi subprocess
 * runs in that project's directory, and transcripts are isolated per project.
 */

let harness: E2eHarness;
const projectA = mkdtempSync(path.join(tmpdir(), "proj-alpha-"));
const projectB = mkdtempSync(path.join(tmpdir(), "proj-beta-"));

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
});

test.afterAll(async () => {
  await harness.close();
});

test("adding and switching projects scopes sessions to the project cwd", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  // Add project A via the sidebar.
  await page.getByTestId("add-project").click();
  await page.getByTestId("add-project-path").fill(projectA);
  await page.getByTestId("add-project-confirm").click();

  // The header cwd flips to project A's path once its session is live.
  await expect(page.getByTestId("session-cwd")).toHaveText(projectA);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  // The server-side session really is scoped to the project.
  const sessions = (await (await fetch(`${harness.baseUrl}/sessions`)).json()) as {
    sessions: SessionMeta[];
  };
  const projectSession = sessions.sessions.find((s) => s.cwd === projectA);
  expect(projectSession).toBeDefined();
  expect(projectSession!.projectId).toBeDefined();

  // Chat in project A.
  await page.getByTestId("composer-input").fill("message for alpha");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("user-cell")).toContainText("message for alpha");
  await expect(page.getByTestId("assistant-text")).toContainText("message for alpha", {
    timeout: 30_000,
  });

  // Add and switch to project B: fresh, empty transcript in B's cwd.
  await page.getByTestId("add-project").click();
  await page.getByTestId("add-project-path").fill(projectB);
  await page.getByTestId("add-project-confirm").click();
  await expect(page.getByTestId("session-cwd")).toHaveText(projectB);
  await expect(page.getByTestId("user-cell")).toHaveCount(0);

  // Switching back to A restores its transcript from the server snapshot.
  await page.getByTestId(`project-${path.basename(projectA)}`).click();
  await expect(page.getByTestId("session-cwd")).toHaveText(projectA);
  await expect(page.getByTestId("user-cell")).toContainText("message for alpha");
  await expect(page.getByTestId("assistant-text")).toContainText("message for alpha");
});

test("the Projects screen toggles enabled state and hides entries", async ({ page }) => {
  const name = path.basename(projectB);
  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-projects").click();

  const row = page.locator(`[data-project-name="${name}"]`);
  await expect(row).toBeVisible();

  // Disable: the sidebar entry disappears (enabled filter hides the row too).
  await page.getByTestId(`project-enabled-${name}`).click();
  await expect(page.getByTestId(`project-${name}`)).toHaveCount(0);
  await expect(row).toHaveCount(0);
  await page.getByTestId("project-filter-disabled").click();
  await expect(row).toBeVisible();

  // Re-enable, then hide: the registry entry goes away entirely.
  await page.getByTestId(`project-enabled-${name}`).click();
  await page.getByTestId("project-filter-all").click();
  await page.getByTestId(`project-hide-${name}`).click();
  await expect(row).toHaveCount(0);
  await expect(page.getByTestId(`project-${name}`)).toHaveCount(0);
});
