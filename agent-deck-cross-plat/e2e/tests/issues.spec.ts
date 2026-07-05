import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Tier-3 gate (Issues screen): a project's GitHub issues (via the gh CLI,
 * stubbed here for hermeticity) list, and selecting one starts a new session
 * with the composer seeded from the issue.
 */

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-issues-"));

test.beforeAll(async () => {
  // Stub gh so the test needs no network or real repo.
  const stub = path.join(mkdtempSync(path.join(tmpdir(), "gh-stub-")), "gh");
  writeFileSync(
    stub,
    `#!/bin/sh\ncat <<'JSON'\n[{"number":7,"title":"Fix the flux capacitor","state":"OPEN","url":"https://github.com/x/y/issues/7","labels":[{"name":"bug"}]}]\nJSON\n`,
  );
  chmodSync(stub, 0o755);
  process.env.AGENT_DECK_GH_BIN = stub;

  harness = await startHarness({ chunkDelayMs: 20 });
  const response = await fetch(`${harness.baseUrl}/projects`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ path: project }),
  });
  if (!response.ok) throw new Error(await response.text());
});

test.afterAll(async () => {
  delete process.env.AGENT_DECK_GH_BIN;
  await harness.close();
});

test("the Default workspace prompts to pick a project", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-issues").click();
  await expect(page.getByTestId("issues-no-project")).toBeVisible();
});

test("lists a project's issues and starts a session seeded from one", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  await page.getByTestId("nav-issues").click();

  const issue = page.getByTestId("issue-7");
  await expect(issue).toBeVisible();
  await expect(issue).toContainText("Fix the flux capacitor");
  await expect(issue).toContainText("bug");

  // Selecting it starts a chat with the composer seeded from the issue.
  await issue.click();
  await expect(page.getByTestId("composer-input")).toHaveValue(
    /issue #7: Fix the flux capacitor/,
  );
});
