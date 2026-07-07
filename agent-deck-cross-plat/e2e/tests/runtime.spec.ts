import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Stage-F gate (runtime screens): the Environment inspector shows masked
 * .env values with scope + override flags, and Doctor reports a healthy pi
 * binary (the harness resolves the real pi) with version.
 */

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-runtime-"));

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
  mkdirSync(path.join(harness.piHome, ".pi", "agent"), { recursive: true });
  writeFileSync(
    path.join(harness.piHome, ".pi", "agent", ".env"),
    "OPENAI_API_KEY=sk-secret-value-1234\nSHARED_KEY=global-value\n",
  );
  mkdirSync(path.join(project, ".pi"), { recursive: true });
  writeFileSync(path.join(project, ".pi", ".env"), "SHARED_KEY=project-value\n");

  const response = await fetch(`${harness.baseUrl}/projects`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ path: project }),
  });
  if (!response.ok) throw new Error(await response.text());
});

test.afterAll(async () => {
  await harness.close();
});

test("environment inspector masks values and flags overrides", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await expect(page.getByTestId("session-cwd")).toHaveText(project);

  await page.getByTestId("nav-environment").click();

  const apiKeyRow = page.locator('[data-env-key="OPENAI_API_KEY"]');
  await expect(apiKeyRow).toBeVisible();
  // The full secret is never rendered — only a masked tail.
  await expect(apiKeyRow).not.toContainText("sk-secret-value-1234");
  await expect(apiKeyRow).toContainText("1234");
  // Each row names its source .env file (native 5.2).
  await expect(apiKeyRow.getByTestId("env-source")).toContainText(".env");

  // SHARED_KEY exists globally (overridden) and in the project.
  const sharedRows = page.locator('[data-env-key="SHARED_KEY"]');
  await expect(sharedRows).toHaveCount(2);
});

test("doctor reports a healthy pi binary with a version", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-doctor").click();

  const binCheck = page.locator('[data-check-id="pi-binary"]');
  await expect(binCheck).toBeVisible();
  await expect(binCheck).toHaveAttribute("data-check-status", "ok");

  const versionCheck = page.locator('[data-check-id="pi-version"]');
  await expect(versionCheck).toHaveAttribute("data-check-status", "ok");
  await expect(versionCheck).toContainText("0.80.3");

  // Node.js runtime check: pi is a Node CLI, so it's a first-class preflight.
  // The e2e runner is on Node ≥ pi's minimum, so it reports ok.
  const nodeCheck = page.locator('[data-check-id="node"]');
  await expect(nodeCheck).toBeVisible();
  await expect(nodeCheck).toHaveAttribute("data-check-status", "ok");
  await expect(nodeCheck).toContainText("Node.js");

  // The GitHub CLI check is surfaced (its ok/warn verdict depends on the host's
  // gh install/auth, so only its presence is asserted here).
  const githubCheck = page.locator('[data-check-id="github"]');
  await expect(githubCheck).toBeVisible();
  await expect(githubCheck).toContainText("GitHub CLI");

  // Re-check button works.
  await page.getByTestId("doctor-refresh").click();
  await expect(page.locator('[data-check-id="pi-binary"]')).toBeVisible();
});

test("Doctor offers a copyable fix command for a failing check", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-write"]);
  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-doctor").click();

  // The provider-credentials check warns (no auth.json in the harness) and
  // exposes a copyable fix command; an ok check (pi-binary) does not.
  const authCheck = page.locator('[data-check-id="auth"]');
  await expect(authCheck).toHaveAttribute("data-check-status", "warn");
  const copyBtn = authCheck.getByTestId("doctor-fix-copy");
  await expect(copyBtn).toHaveAttribute("data-fix-command", /API_KEY/);
  await expect(
    page.locator('[data-check-id="pi-binary"]').getByTestId("doctor-fix-copy"),
  ).toHaveCount(0);

  // Clicking copies the command and flips the label to "Copied".
  await copyBtn.click();
  await expect(copyBtn).toHaveText(/Copied/);
});
