import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, selectProject, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Tier-2 gate (draft startup cards): an empty session previews what it will
 * launch with — agent, project cwd, assigned skills — instead of a blank
 * transcript, and the card clears once the first message lands.
 */

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-startup-"));

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
  const skillDir = path.join(project, ".pi", "skills", "tidy-commits");
  mkdirSync(skillDir, { recursive: true });
  writeFileSync(
    path.join(skillDir, "SKILL.md"),
    "---\nname: tidy-commits\ndescription: Write tidy commits\n---\n\nHow.\n",
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

test("an empty session shows a startup card that clears after the first message", async ({
  page,
}) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  const card = page.getByTestId("session-startup");
  await expect(card).toBeVisible();
  await expect(page.getByTestId("startup-agent")).toHaveText("Pi Agent");
  await expect(page.getByTestId("startup-skills")).toContainText("None assigned");

  await page.getByTestId("composer-input").fill("hi there");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("user-cell")).toBeVisible();
  await expect(card).toBeHidden();
});

test("the startup card previews the project's assigned skills", async ({ page }) => {
  const { projects } = (await (await fetch(`${harness.baseUrl}/projects`)).json()) as {
    projects: Array<{ id: string; path: string }>;
  };
  const id = projects.find((p) => p.path === project)!.id;
  const patch = await fetch(`${harness.baseUrl}/projects/${id}`, {
    method: "PATCH",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ assignedSkills: ["tidy-commits"] }),
  });
  expect(patch.ok).toBe(true);

  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(project));
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  await page.getByTestId("new-chat").click();

  await expect(page.getByTestId("session-startup")).toBeVisible();
  await expect(page.getByTestId("startup-skills")).toContainText("tidy-commits");
});
