import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Memory screen (the visible half): a project's stored memories list with type
 * + status chips, and the pin / edit / delete actions wired to the /memory
 * REST routes. A memory is seeded over REST, then driven through the UI.
 */

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-memory-"));

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

test("the Default workspace prompts to open a project for memory", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-memory").click();
  await expect(page.getByTestId("memory-no-project")).toBeVisible();
});

test("lists a project's memories and pins, edits, and deletes one", async ({ page }) => {
  // Seed a memory into the project over REST.
  const projectsRes = await fetch(`${harness.baseUrl}/projects`);
  const { projects } = (await projectsRes.json()) as {
    projects: Array<{ id: string; path: string }>;
  };
  const projectId = projects.find((p) => p.path === project)!.id;
  const created = await fetch(`${harness.baseUrl}/memory`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      projectId,
      type: "decision",
      title: "Use pnpm workspaces",
      summary: "The monorepo is a pnpm workspace",
      body: "We use pnpm, not npm or yarn.",
    }),
  });
  const { memory } = (await created.json()) as { memory: { id: string } };

  await page.goto(harness.baseUrl);
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  await page.getByTestId("nav-memory").click();

  const row = page.getByTestId(`memory-${memory.id}`);
  await expect(row).toBeVisible();
  await expect(row).toContainText("Use pnpm workspaces");
  await expect(row).toHaveAttribute("data-status", "active");

  // Pin it → the status chip flips to pinned.
  await page.getByTestId(`memory-pin-${memory.id}`).click();
  await expect(row).toHaveAttribute("data-status", "pinned");

  // Edit the summary.
  await row.click();
  await page.getByTestId("memory-summary").fill("The monorepo uses pnpm workspaces exclusively");
  await page.getByTestId("memory-save").click();
  await expect(row).toContainText("pnpm workspaces exclusively");

  // Delete it → the row disappears.
  await page.getByTestId(`memory-delete-${memory.id}`).click();
  await expect(page.getByTestId(`memory-${memory.id}`)).toHaveCount(0);
  await expect(page.getByTestId("memory-empty")).toBeVisible();
});
