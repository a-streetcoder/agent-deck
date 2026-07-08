import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Loop run UI (native LoopLaunch, minimal): running a loop from the Bank drives
 * its agent (a real pi subagent via the harness mock provider) and the live
 * panel polls the run to completion. validationCommand `exit 0` → completed.
 */

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-looprun-"));

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
  const response = await fetch(`${harness.baseUrl}/projects`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ path: project }),
  });
  if (!response.ok) throw new Error(await response.text());
  // Seed a loop that succeeds on the first validation.
  const put = await fetch(`${harness.baseUrl}/loops`, {
    method: "PUT",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      name: "Green Suite",
      goal: "Make it pass.",
      validationCommand: "exit 0",
      maxIterations: 3,
    }),
  });
  if (!put.ok) throw new Error(await put.text());
});

test.afterAll(async () => {
  await harness.close();
});

test("runs a loop from the Bank and the panel reaches completed", async ({ page }) => {
  await page.goto(harness.baseUrl);
  // A run needs a current project.
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await expect(page.getByTestId("session-cwd")).toHaveText(project);

  await page.getByTestId("nav-loops").click();
  const row = page.locator('[data-loop-name="Green Suite"]');
  await expect(row).toBeVisible();

  // Run it → the live panel appears and polls to completion.
  await page.getByTestId("loop-run-Green Suite").click();
  await expect(page.getByTestId("loop-run-panel")).toBeVisible();
  await expect(page.getByTestId("loop-run-status")).toHaveAttribute("data-status", "completed", {
    timeout: 30_000,
  });
  // The first iteration passed validation.
  await expect(page.getByTestId("loop-run-iterations")).toContainText("✓");
  // A completion toast fires.
  await expect(page.getByTestId("toast")).toHaveText(/completed/);
});
