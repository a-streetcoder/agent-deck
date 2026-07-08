import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Stage-J gate (project auto-discovery): configure a root folder, scan it,
 * and one-click add a discovered project with a detected type.
 */

let harness: E2eHarness;
const devRoot = mkdtempSync(path.join(tmpdir(), "dev-root-"));

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
  // A rust project (a git repo, as discovery requires .git/package.json/Xcode
  // to surface a dir) and a react project; one non-project folder.
  mkdirSync(path.join(devRoot, "rusty", ".git"), { recursive: true });
  writeFileSync(path.join(devRoot, "rusty", ".git", "HEAD"), "ref: refs/heads/main\n");
  writeFileSync(path.join(devRoot, "rusty", "Cargo.toml"), "[package]\nname='rusty'\n");
  mkdirSync(path.join(devRoot, "webby"), { recursive: true });
  writeFileSync(
    path.join(devRoot, "webby", "package.json"),
    JSON.stringify({ dependencies: { react: "19" } }),
  );
  mkdirSync(path.join(devRoot, "just-notes"), { recursive: true });
  writeFileSync(path.join(devRoot, "just-notes", "todo.txt"), "nothing");
});

test.afterAll(async () => {
  await harness.close();
});

test("configure a root, discover projects, and add one", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-projects").click();

  // Add the dev root.
  await page.getByTestId("discovery-root-input").fill(devRoot);
  await page.getByTestId("discovery-root-add").click();
  await expect(page.getByTestId("discovery-root-chip")).toContainText(path.basename(devRoot));

  // Both projects are discovered; the non-project is not.
  await expect(page.locator('[data-candidate-name="rusty"]')).toBeVisible();
  await expect(page.locator('[data-candidate-name="webby"]')).toContainText("react");
  await expect(page.locator('[data-candidate-name="just-notes"]')).toHaveCount(0);

  // Add rusty → it appears in the Library with its type badge and leaves
  // the discovery list (now registered).
  await page.getByTestId("discovery-add-rusty").click();
  const row = page.locator('[data-project-name="rusty"]');
  await expect(row).toBeVisible();
  await expect(row.getByTestId("project-type-badge")).toHaveText("rust");
  await expect(page.locator('[data-candidate-name="rusty"]')).toHaveCount(0);

  // The registered project is now selectable in the sidebar.
  await expect(page.getByTestId("project-rusty")).toBeVisible();
});
