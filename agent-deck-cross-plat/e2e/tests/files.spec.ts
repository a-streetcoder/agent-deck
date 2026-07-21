import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, selectProject, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Slice 13b gate: the file-navigation panel + read-only preview against the
 * REAL stack. A scratch project with a deterministic tree (a subdirectory with
 * a text file, a small PNG, a NUL-containing binary) is added as a project;
 * the web panel lazily lists the root, expands the subdirectory over `file_list`,
 * previews the text file's content, and shows the image / binary states. No pi
 * turn is needed — the files exist on disk; the panel browses the session cwd.
 */

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-files-"));

const TEXT_CONTENT = "hello from the files panel\nsecond line here\nthird line\n";
// A minimal valid 1x1 PNG (the smallest deterministic image payload).
const PNG_BASE64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC";

test.beforeAll(async () => {
  mkdirSync(path.join(project, "src"));
  writeFileSync(path.join(project, "src", "hello.txt"), TEXT_CONTENT);
  writeFileSync(path.join(project, "logo.png"), Buffer.from(PNG_BASE64, "base64"));
  // A binary: leading NUL bytes make the server's read sniff it as binary.
  writeFileSync(path.join(project, "data.bin"), Buffer.from([0, 1, 2, 0, 255, 0, 42]));

  harness = await startHarness({ reply: () => "ok", chunkDelayMs: 0 });
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

test("browse the tree, preview a text file, and see image + binary states", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(project));
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  await page.getByTestId("new-chat").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  // Open the panel: the toggle shows for any chat session (ungated by git).
  const toggle = page.getByTestId("files-toggle");
  await expect(toggle).toBeVisible();
  await toggle.click();
  const panel = page.getByTestId("files-panel");
  await expect(panel).toBeVisible();

  // The root lists lazily: the `src` directory plus the two root files
  // (directories first). The subdirectory's contents are NOT fetched yet.
  await expect(page.locator('[data-testid="file-tree-dir"][data-path="src"]')).toBeVisible({
    timeout: 15_000,
  });
  await expect(page.locator('[data-testid="file-tree-file"][data-path="logo.png"]')).toBeVisible();
  await expect(page.locator('[data-testid="file-tree-file"][data-path="data.bin"]')).toBeVisible();
  await expect(
    page.locator('[data-testid="file-tree-file"][data-path="src/hello.txt"]'),
  ).toHaveCount(0);

  // Expand `src`: its listing loads over `file_list` and the text file appears.
  await page.locator('[data-testid="file-tree-dir"][data-path="src"]').click();
  const textRow = page.locator('[data-testid="file-tree-file"][data-path="src/hello.txt"]');
  await expect(textRow).toBeVisible({ timeout: 15_000 });

  // Open the text file: the read-only preview renders its content.
  await textRow.click();
  await expect(page.getByTestId("file-preview")).toBeVisible();
  await expect(page.getByTestId("file-preview-path")).toHaveText("src/hello.txt");
  await expect(page.getByTestId("file-preview-text")).toContainText("hello from the files panel", {
    timeout: 15_000,
  });
  await expect(page.getByTestId("file-preview-text")).toContainText("third line");

  // Open the image (its row stays in the tree strip above the preview): the
  // whole-file data URI renders in an <img>.
  await page.locator('[data-testid="file-tree-file"][data-path="logo.png"]').click();
  const image = page.getByTestId("file-preview-image");
  await expect(image).toBeVisible({ timeout: 15_000 });
  await expect(image.locator("img")).toHaveAttribute("src", /^data:image\/png;base64,/);

  // Open the binary: it degrades to the binary placeholder (no preview).
  await page.locator('[data-testid="file-tree-file"][data-path="data.bin"]').click();
  await expect(page.getByTestId("file-preview-binary")).toBeVisible({ timeout: 15_000 });
  await expect(page.getByTestId("file-preview-binary")).toContainText("Binary file");

  // Back to the tree, then close the panel.
  await page.getByTestId("file-back").click();
  await expect(page.getByTestId("file-preview")).toHaveCount(0);
  await page.getByTestId("files-close").click();
  await expect(panel).toHaveCount(0);
});
