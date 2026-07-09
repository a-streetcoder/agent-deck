import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, selectProject, test } from "../helpers/fixtures.ts";
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

test("the All Projects workspace prompts to open a project for memory", async ({ page }) => {
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
  await selectProject(page, path.basename(project));
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  await page.getByTestId("nav-memory").click();

  const row = page.getByTestId(`memory-${memory.id}`);
  await expect(row).toBeVisible();
  await expect(row).toContainText("Use pnpm workspaces");
  await expect(row).toHaveAttribute("data-status", "active");

  // Status sections (native §11.1): the memory sits under Active, and no Pinned
  // section exists yet.
  await expect(page.getByTestId("memory-section-active")).toContainText("Use pnpm workspaces");
  await expect(page.getByTestId("memory-section-pinned")).toHaveCount(0);

  // Pin it → the status chip flips to pinned and it moves to the Pinned section.
  await page.getByTestId(`memory-pin-${memory.id}`).click();
  await expect(row).toHaveAttribute("data-status", "pinned");
  await expect(page.getByTestId("memory-section-pinned")).toContainText("Use pnpm workspaces");
  await expect(page.getByTestId("memory-section-active")).toHaveCount(0);

  // Edit the summary.
  await row.click();
  await page.getByTestId("memory-summary").fill("The monorepo uses pnpm workspaces exclusively");
  await page.getByTestId("memory-save").click();
  await expect(row).toContainText("pnpm workspaces exclusively");

  // Delete it (confirm-gated, native parity) → the row disappears.
  page.once("dialog", (dialog) => void dialog.accept());
  await page.getByTestId(`memory-delete-${memory.id}`).click();
  await expect(page.getByTestId(`memory-${memory.id}`)).toHaveCount(0);
  await expect(page.getByTestId("memory-empty")).toBeVisible();
});

test("recall search surfaces the relevant memory and hides the rest (native 11.8)", async ({
  page,
}) => {
  const projectsRes = await fetch(`${harness.baseUrl}/projects`);
  const { projects } = (await projectsRes.json()) as {
    projects: Array<{ id: string; path: string }>;
  };
  const projectId = projects.find((p) => p.path === project)!.id;

  async function seed(type: string, title: string, summary: string, body: string): Promise<string> {
    const res = await fetch(`${harness.baseUrl}/memory`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ projectId, type, title, summary, body }),
    });
    const { memory } = (await res.json()) as { memory: { id: string } };
    return memory.id;
  }

  const relevantId = await seed(
    "runbook",
    "Rollback a failed database migration",
    "run the down migration and restore the postgres snapshot",
    "steps for a broken migration",
  );
  const irrelevantId = await seed(
    "context",
    "Favourite lunch spots near the office",
    "tacos and ramen",
    "unrelated trivia",
  );

  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(project));
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  await page.getByTestId("nav-memory").click();

  // Both memories are visible with no query.
  await expect(page.getByTestId(`memory-${relevantId}`)).toBeVisible();
  await expect(page.getByTestId(`memory-${irrelevantId}`)).toBeVisible();

  // Query the recall engine → only the relevant memory survives, under a
  // dedicated "Recall results" section.
  await page.getByTestId("memory-search").fill("rollback database migration");
  await expect(page.getByTestId("memory-section-recall")).toContainText(
    "Rollback a failed database migration",
  );
  await expect(page.getByTestId(`memory-${relevantId}`)).toBeVisible();
  await expect(page.getByTestId(`memory-${irrelevantId}`)).toHaveCount(0);

  // A query with no overlap abstains → the search-empty state shows.
  await page.getByTestId("memory-search").fill("quantum helicopter");
  await expect(page.getByTestId("memory-search-empty")).toBeVisible();

  // Clearing the field restores the full status-grouped list.
  await page.getByTestId("memory-search").fill("");
  await expect(page.getByTestId(`memory-${relevantId}`)).toBeVisible();
  await expect(page.getByTestId(`memory-${irrelevantId}`)).toBeVisible();

  // Clean up the seeded memories.
  await fetch(`${harness.baseUrl}/memory/${relevantId}?projectId=${projectId}`, {
    method: "DELETE",
  });
  await fetch(`${harness.baseUrl}/memory/${irrelevantId}?projectId=${projectId}`, {
    method: "DELETE",
  });
});
