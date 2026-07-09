import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, selectProject, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Tier-3 gate (Instructions screen): editing a project's AGENTS.md through the
 * screen writes pi's canonical project-context file to disk and reloads it.
 */

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-instructions-"));
const projectB = mkdtempSync(path.join(tmpdir(), "proj-instructions-b-"));

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
  for (const p of [project, projectB]) {
    const response = await fetch(`${harness.baseUrl}/projects`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path: p }),
    });
    if (!response.ok) throw new Error(await response.text());
  }
});

test.afterAll(async () => {
  await harness.close();
});

test("the All Projects workspace edits Global; Project scope prompts to pick one", async ({
  page,
}) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-instructions").click();
  // No project selected → Global scope by default, so the editor is available.
  await expect(page.getByTestId("instructions-editor")).toBeVisible();
  // Toggling to Project scope (with no project) shows the pick-a-project prompt.
  await page.getByTestId("instructions-scope-project").click();
  await expect(page.getByTestId("instructions-no-project")).toBeVisible();
});

test("editing Global AGENTS.md writes ~/.pi/agent/AGENTS.md", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-instructions").click();
  await page.getByTestId("instructions-scope-global").click();

  const editor = page.getByTestId("instructions-editor");
  await expect(editor).toBeVisible();
  await editor.fill("# Global rules\n\nPrefer small PRs.");
  await page.getByTestId("instructions-save").click();
  await expect(page.getByTestId("instructions-save")).toHaveText("Saved");

  // On disk at the global path pi loads for every session.
  const globalFile = path.join(harness.piHome, ".pi", "agent", "AGENTS.md");
  await expect.poll(() => existsSync(globalFile)).toBe(true);
  expect(readFileSync(globalFile, "utf8")).toContain("Prefer small PRs.");
});

test("editing a project's AGENTS.md writes it to disk and reloads", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(project));
  await expect(page.getByTestId("session-cwd")).toHaveText(project);

  await page.getByTestId("nav-instructions").click();
  const editor = page.getByTestId("instructions-editor");
  await expect(editor).toBeVisible();
  await editor.fill("# House rules\n\nAlways write tidy commits.");
  await page.getByTestId("instructions-save").click();
  await expect(page.getByTestId("instructions-save")).toHaveText("Saved");

  // On disk where pi loads it.
  const file = path.join(project, "AGENTS.md");
  expect(existsSync(file)).toBe(true);
  expect(readFileSync(file, "utf8")).toContain("Always write tidy commits.");

  // And it reloads from disk on a fresh visit.
  await page.reload();
  await selectProject(page, path.basename(project));
  await page.getByTestId("nav-instructions").click();
  await expect(page.getByTestId("instructions-editor")).toHaveValue(/Always write tidy commits\./);
});

test("switching projects reloads instructions and never saves stale content", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(project));
  await page.getByTestId("nav-instructions").click();
  const editor = page.getByTestId("instructions-editor");
  await expect(editor).toBeVisible();
  await editor.fill("edits for project A that must not leak");

  // Switch to project B while on the screen: the editor reloads B's (empty)
  // AGENTS.md — A's dirty content must not carry over or be saveable to B.
  await selectProject(page, path.basename(projectB));
  await expect(editor).toHaveValue("");
  await expect(page.getByTestId("instructions-save")).toHaveText("Saved");

  // B's file on disk stays untouched by A's edits.
  const fileB = path.join(projectB, "AGENTS.md");
  if (existsSync(fileB)) {
    expect(readFileSync(fileB, "utf8")).not.toContain("must not leak");
  }
});

test("edits a project's CLAUDE.md when it has no AGENTS.md", async ({ page }) => {
  const claudeProject = mkdtempSync(path.join(tmpdir(), "proj-claude-"));
  writeFileSync(path.join(claudeProject, "CLAUDE.md"), "# Claude\n\nExisting claude instructions.");
  const res = await fetch(`${harness.baseUrl}/projects`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ path: claudeProject }),
  });
  if (!res.ok) throw new Error(await res.text());

  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(claudeProject));
  await page.getByTestId("nav-instructions").click();

  // The editor loads CLAUDE.md's content, and the header names the resolved file.
  const editor = page.getByTestId("instructions-editor");
  await expect(editor).toHaveValue(/Existing claude instructions/);
  await expect(page.getByTestId("instructions-screen")).toContainText("CLAUDE.md");

  // Saving writes back to CLAUDE.md — it does not create a shadowing AGENTS.md.
  await editor.fill("Edited claude instructions.");
  await page.getByTestId("instructions-save").click();
  await expect(page.getByTestId("instructions-save")).toHaveText("Saved");
  await expect
    .poll(() => readFileSync(path.join(claudeProject, "CLAUDE.md"), "utf8"))
    .toContain("Edited claude instructions.");
  expect(existsSync(path.join(claudeProject, "AGENTS.md"))).toBe(false);
});
