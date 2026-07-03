import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Slice-9 gate: editing through the UI is edit-safe. A builtin edit becomes a
 * settings.json override (builtin file bytes NEVER change) and a new project
 * agent created in the editor lands on disk and becomes pickable.
 */

const BUILTIN_CODER = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
  "packages",
  "resources",
  "builtin-agents",
  "coder.md",
);

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-edit-"));

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
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

test("editing a builtin writes an override and never mutates the builtin file", async ({
  page,
}) => {
  const bytesBefore = readFileSync(BUILTIN_CODER);

  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-agents").click();
  await page.locator('[data-agent-name="coder"]').click();
  await expect(page.getByTestId("agent-editor")).toBeVisible();

  await page.getByTestId("editor-description").fill("My customized coder");
  await page.getByTestId("editor-save").click();
  await expect(page.getByTestId("agent-editor")).toHaveCount(0);

  const coderRow = page.locator('[data-agent-name="coder"]');
  await expect(coderRow).toContainText("My customized coder");
  await expect(coderRow.getByTestId("overridden-badge")).toBeVisible();

  // THE guarantee: the bundled builtin file is byte-identical.
  expect(readFileSync(BUILTIN_CODER).equals(bytesBefore)).toBe(true);
});

test("creating a project agent in the editor lands on disk and is pickable", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await expect(page.getByTestId("session-cwd")).toHaveText(project);

  await page.getByTestId("nav-agents").click();
  await page.getByTestId("new-agent").click();
  await page.getByTestId("editor-name").fill("waffle-bot");
  await page.getByTestId("editor-scope").selectOption("project");
  await page.getByTestId("editor-description").fill("Waffles only");
  await page.getByTestId("editor-body").fill("You are waffle-bot.");
  await page.getByTestId("editor-save").click();
  await expect(page.getByTestId("agent-editor")).toHaveCount(0);

  const row = page.locator('[data-agent-name="waffle-bot"]');
  await expect(row).toBeVisible();
  await expect(row.getByTestId("scope-chip")).toHaveAttribute("data-scope", "project");

  // On disk where pi expects it…
  const content = readFileSync(path.join(project, ".pi", "agents", "waffle-bot.md"), "utf8");
  expect(content).toContain("You are waffle-bot.");

  // …and pickable in the composer.
  await page.getByTestId("nav-chat").click();
  await expect(page.getByTestId("agent-picker").locator('option[value="waffle-bot"]')).toHaveCount(
    1,
  );
});

test("editing a skill updates its SKILL.md without losing the body", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await expect(page.getByTestId("session-cwd")).toHaveText(project);

  await page.getByTestId("nav-skills").click();
  await page.getByTestId("new-skill").click();
  await page.getByTestId("skill-editor-name").fill("changelog");
  await page.getByTestId("skill-editor-scope").selectOption("project");
  await page.getByTestId("skill-editor-description").fill("Write changelogs");
  await page.getByTestId("skill-editor-body").fill("How to write a changelog.");
  await page.getByTestId("skill-editor-save").click();
  await expect(page.getByTestId("skill-editor")).toHaveCount(0);

  const row = page.locator('[data-skill-name="changelog"]');
  await expect(row).toBeVisible();

  // Re-open and change only the description: the body must survive.
  await row.click();
  await expect(page.getByTestId("skill-editor-body")).toHaveValue("How to write a changelog.");
  await page.getByTestId("skill-editor-description").fill("Write excellent changelogs");
  await page.getByTestId("skill-editor-save").click();
  await expect(page.getByTestId("skill-editor")).toHaveCount(0);

  const content = readFileSync(
    path.join(project, ".pi", "skills", "changelog", "SKILL.md"),
    "utf8",
  );
  expect(content).toContain("Write excellent changelogs");
  expect(content).toContain("How to write a changelog.");
});
