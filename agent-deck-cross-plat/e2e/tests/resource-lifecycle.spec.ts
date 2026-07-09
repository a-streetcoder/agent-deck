import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { expect, selectProject, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Stage-H gate (agent & skill lifecycle): disable excludes from the picker /
 * injection and dims the row; delete removes a custom agent's file and a
 * skill's dir; disabling a builtin never mutates the bundled file.
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
const project = mkdtempSync(path.join(tmpdir(), "proj-lifecycle-"));

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
  const agentsDir = path.join(project, ".pi", "agents");
  mkdirSync(agentsDir, { recursive: true });
  writeFileSync(
    path.join(agentsDir, "toaster.md"),
    "---\nname: toaster\ndescription: Toast things\n---\n\nYou are toaster.\n",
  );
  const skillDir = path.join(project, ".pi", "skills", "crumbs");
  mkdirSync(skillDir, { recursive: true });
  writeFileSync(
    path.join(skillDir, "SKILL.md"),
    "---\nname: crumbs\ndescription: Sweep crumbs\n---\n\nHow to sweep.\n",
  );
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

test("disabling a builtin agent leaves the bundled file untouched", async ({ page }) => {
  const before = readFileSync(BUILTIN_CODER);
  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-agents").click();
  await page.locator('[data-agent-name="coder"]').click();
  await page.getByTestId("agent-disable").click();

  await expect(
    page.locator('[data-agent-name="coder"]').getByTestId("disabled-badge"),
  ).toBeVisible();
  expect(readFileSync(BUILTIN_CODER).equals(before)).toBe(true);

  // Re-enable to leave state clean for other tests.
  await page.getByTestId("agent-disable").click();
  await expect(page.locator('[data-agent-name="coder"]').getByTestId("disabled-badge")).toHaveCount(
    0,
  );
});

test("a disabled agent disappears from the composer picker", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(project));
  await expect(page.getByTestId("session-cwd")).toHaveText(project);

  // toaster is pickable to start.
  await expect(page.getByTestId("agent-picker").locator('option[value="toaster"]')).toHaveCount(1);

  await page.getByTestId("nav-agents").click();
  await page.locator('[data-agent-name="toaster"]').click();
  await page.getByTestId("agent-disable").click();
  await expect(
    page.locator('[data-agent-name="toaster"]').getByTestId("disabled-badge"),
  ).toBeVisible();

  // Now it's gone from the picker.
  await page.getByTestId("new-chat").click();
  await expect(page.getByTestId("agent-picker").locator('option[value="toaster"]')).toHaveCount(0);
});

test("deleting a project agent removes its file", async ({ page }) => {
  const agentFile = path.join(project, ".pi", "agents", "toaster.md");
  expect(existsSync(agentFile)).toBe(true);

  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(project));
  await page.getByTestId("nav-agents").click();
  await page.locator('[data-agent-name="toaster"]').click();

  page.on("dialog", (dialog) => void dialog.accept());
  await page.getByTestId("agent-delete").click();

  await expect(page.locator('[data-agent-name="toaster"]')).toHaveCount(0);
  expect(existsSync(agentFile)).toBe(false);
});

test("disabling a skill excludes it from injection; delete removes its dir", async ({ page }) => {
  const skillDir = path.join(project, ".pi", "skills", "crumbs");
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(project));
  await page.getByTestId("nav-skills").click();

  // Assign crumbs, then disable it — a new session must NOT load /skill:crumbs.
  await page.locator('[data-skill-name="crumbs"]').click();
  await page.getByTestId(`assign-skill-crumbs-${path.basename(project)}`).check();
  await page.getByTestId("skill-disable").click();
  await expect(
    page.locator('[data-skill-name="crumbs"]').getByTestId("skill-disabled-badge"),
  ).toBeVisible();

  const { projects } = (await (await fetch(`${harness.baseUrl}/projects`)).json()) as {
    projects: Array<{ id: string; path: string }>;
  };
  const projectId = projects.find((p) => p.path === project)!.id;
  const created = await fetch(`${harness.baseUrl}/sessions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ projectId }),
  });
  const { session } = (await created.json()) as { session: { id: string } };
  await expect
    .poll(async () => {
      const response = await fetch(`${harness.baseUrl}/sessions/${session.id}/commands`);
      if (!response.ok) return ["pending"];
      const { commands } = (await response.json()) as {
        commands: Array<{ name: string; source: string }>;
      };
      return commands.filter((c) => c.source === "skill").map((c) => c.name);
    })
    .not.toContain("skill:crumbs");

  // Delete removes the dir.
  expect(existsSync(skillDir)).toBe(true);
  page.on("dialog", (dialog) => void dialog.accept());
  await page.getByTestId("skill-delete").click();
  await expect(page.locator('[data-skill-name="crumbs"]')).toHaveCount(0);
  expect(existsSync(skillDir)).toBe(false);
});
