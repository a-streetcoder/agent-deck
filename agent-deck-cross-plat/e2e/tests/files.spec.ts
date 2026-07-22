import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, selectProject, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Slice 13b + L4a gate: the file-navigation panel against the REAL stack, now in
 * the L4a side-by-side [tree | content] + multi-file-tab model. A scratch project
 * with a deterministic tree (a subdirectory with a text file, a small PNG, a
 * NUL-containing binary, a markdown file) is added as a project; the web panel
 * lazily lists the root, expands the subdirectory over `file_list`, opens files
 * as Chrome-style tabs (syntax-highlighted CodeMirror for text), shows the image
 * / binary states, keeps multiple files open (keep-alive), and offers the
 * markdown raw/preview toggle. No pi turn is needed — the files exist on disk.
 */

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-files-"));

const TEXT_CONTENT = "hello from the files panel\nsecond line here\nthird line\n";
const MARKDOWN_CONTENT = "# Fixture Readme\n\nSome **markdown** body text here.\n";
// A minimal valid 1x1 PNG (the smallest deterministic image payload).
const PNG_BASE64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC";

test.beforeAll(async () => {
  mkdirSync(path.join(project, "src"));
  writeFileSync(path.join(project, "src", "hello.txt"), TEXT_CONTENT);
  writeFileSync(path.join(project, "README.md"), MARKDOWN_CONTENT);
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

test("side-by-side tree + multi-file tabs, syntax-highlighted text, image + binary states", async ({
  page,
}) => {
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(project));
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  await page.getByTestId("new-chat").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  // Open the panel: the toggle shows for any chat session (ungated by git). It
  // opens as a TAB in the single right-side workspace pane (Slice L1).
  const toggle = page.getByTestId("files-toggle");
  await expect(toggle).toBeVisible();
  await toggle.click();
  await expect(page.getByTestId("workspace-tab-strip")).toBeVisible();
  await expect(page.getByTestId("workspace-tab-files")).toBeVisible();
  const panel = page.getByTestId("files-panel");
  await expect(panel).toBeVisible();

  // The tree column stays alongside a content column: the tree|content resize
  // handle sits between them (Slice L4a — the draggable split). The handle is a
  // zero-layout-width overlay (so it never shifts its neighbors), so assert it is
  // present rather than "visible" (a 0px-wide box reads as hidden to Playwright).
  await expect(page.getByTestId("files-tree-resize")).toBeAttached();
  // Nothing open yet → the content column shows the empty state.
  await expect(page.getByTestId("files-content-empty")).toBeVisible();

  // The root lists lazily: the `src` directory plus the root files (directories
  // first). The subdirectory's contents are NOT fetched yet.
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

  // Open the text file: it opens as a tab; the read-only CodeMirror view renders
  // its content (syntax-highlighted — the .cm-editor mounts).
  await textRow.click();
  await expect(page.getByTestId("files-tab-strip")).toBeVisible();
  await expect(page.getByTestId("files-tab-0")).toHaveText(/hello\.txt/);
  await expect(page.locator('[data-testid="file-preview-path"]:visible')).toHaveText(
    "src/hello.txt",
  );
  const text = page.locator('[data-testid="file-preview-text"]:visible');
  await expect(text).toContainText("hello from the files panel", { timeout: 15_000 });
  await expect(text).toContainText("third line");
  await expect(text.locator(".cm-editor")).toBeVisible();

  // Open the image: a SECOND tab appears (dedupe is by path). The whole-file data
  // URI renders in an <img>.
  await page.locator('[data-testid="file-tree-file"][data-path="logo.png"]').click();
  await expect(page.getByTestId("files-tab-0")).toBeVisible();
  await expect(page.getByTestId("files-tab-1")).toBeVisible();
  const image = page.getByTestId("file-preview-image");
  await expect(image).toBeVisible({ timeout: 15_000 });
  await expect(image.locator("img")).toHaveAttribute("src", /^data:image\/png;base64,/);

  // KEEP-ALIVE: switch back to the first tab — the text body is still mounted and
  // reappears (it was hidden, never unmounted).
  await page.getByTestId("files-tab-0").click();
  await expect(page.locator('[data-testid="file-preview-text"]:visible')).toContainText(
    "hello from the files panel",
  );

  // Open the binary: it degrades to the binary placeholder (no preview).
  await page.locator('[data-testid="file-tree-file"][data-path="data.bin"]').click();
  await expect(page.getByTestId("file-preview-binary")).toBeVisible({ timeout: 15_000 });
  await expect(page.getByTestId("file-preview-binary")).toContainText("Binary file");

  // Close a tab from its strip X — that file's tab and body disappear.
  await page.getByTestId("files-tab-close-0").click();
  await expect(
    page.locator('[data-testid="file-preview-path"][title="src/hello.txt"]'),
  ).toHaveCount(0);

  // Close the whole workspace tab from the strip X — the pane empties + unmounts.
  await page.getByTestId("workspace-tab-close-files").click();
  await expect(page.getByTestId("workspace-tab-files")).toHaveCount(0);
  await expect(panel).toHaveCount(0);
});

test("markdown files offer a raw/preview toggle (default preview)", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(project));
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  await page.getByTestId("new-chat").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  await page.getByTestId("files-toggle").click();
  await expect(page.getByTestId("files-panel")).toBeVisible();

  // Open README.md: a markdown file defaults to the rendered PREVIEW, and the
  // raw/preview toggle is present.
  const mdRow = page.locator('[data-testid="file-tree-file"][data-path="README.md"]');
  await expect(mdRow).toBeVisible({ timeout: 15_000 });
  await mdRow.click();
  await expect(page.getByTestId("file-preview-mode-toggle")).toBeVisible();
  const preview = page.locator('[data-testid="file-preview-markdown"]:visible');
  await expect(preview).toBeVisible();
  // The rendered markdown shows the heading text (not the raw `#`).
  await expect(preview).toContainText("Fixture Readme", { timeout: 15_000 });

  // Toggle to RAW: the CodeMirror text view renders the raw markdown source.
  await page.getByTestId("file-preview-mode-raw").click();
  await expect(page.locator('[data-testid="file-preview-text"]:visible')).toContainText(
    "# Fixture Readme",
  );

  // Back to preview.
  await page.getByTestId("file-preview-mode-preview").click();
  await expect(page.locator('[data-testid="file-preview-markdown"]:visible')).toBeVisible();
});
