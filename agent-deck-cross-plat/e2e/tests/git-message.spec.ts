import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Git "Generate" (native PiAgentShipService): drafting a commit message from the
 * working-tree changes via a pi helper (the harness mock provider returns a
 * fixed message), then filling the message box.
 */

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-gitmsg-"));

test.beforeAll(async () => {
  execFileSync("git", ["init", "-b", "main", project]);
  execFileSync("git", ["config", "user.email", "t@t.local"], { cwd: project });
  execFileSync("git", ["config", "user.name", "T"], { cwd: project });
  writeFileSync(path.join(project, "greet.js"), "export function hello() {}\n");
  execFileSync("git", ["add", "-A"], { cwd: project });
  execFileSync("git", ["commit", "-m", "init"], { cwd: project });
  // An uncommitted change to describe.
  writeFileSync(path.join(project, "greet.js"), "export function hello() {\n  return 'hi';\n}\n");

  harness = await startHarness({ chunkDelayMs: 20, reply: () => "Refine greet.js greeting" });
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

test("Generate drafts a commit message into the box", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  await page.getByTestId("nav-git").click();

  await expect(page.locator('[data-git-path="greet.js"]')).toBeVisible();
  await page.getByTestId("git-generate-message").click();
  // The pi helper's message (the mock reply) lands in the commit box.
  await expect(page.getByTestId("git-commit-message")).toHaveValue(/Refine greet\.js/, {
    timeout: 30_000,
  });
});
