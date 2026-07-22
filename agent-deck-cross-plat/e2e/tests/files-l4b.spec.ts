import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import type { Page } from "@playwright/test";
import { expect, selectProject, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Slice L4b gate against the REAL stack — the two features:
 *   PART A (persist): the Files panel's open-file strip lives in the store, so
 *     closing the Files workspace tab (which unmounts the panel) and reopening it
 *     RESTORES the open file tabs + active file.
 *   PART B (edit + autosave): the CodeMirror text view is EDITABLE; edits
 *     debounce-autosave through file_write; a header status chip reports the
 *     save; binary/truncated files stay read-only; and an on-disk change between
 *     read and write is surfaced as a conflict (never a silent clobber).
 */

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-files-l4b-"));

const HELLO = "hello from the files panel\nsecond line here\nthird line\n";
const NOTES = "first note\nsecond note\n";
// A >1MB text file so the server's bounded read truncates it (read-only guard).
const HUGE = "x".repeat(1_200_000);
// A binary (leading NUL bytes) — the read sniffs it as binary (never editable).
const BIN = Buffer.from([0, 1, 2, 0, 255, 0, 42]);

test.beforeAll(async () => {
  mkdirSync(path.join(project, "src"));
  writeFileSync(path.join(project, "src", "hello.txt"), HELLO);
  writeFileSync(path.join(project, "notes.txt"), NOTES);
  writeFileSync(path.join(project, "huge.txt"), HUGE);
  writeFileSync(path.join(project, "data.bin"), BIN);

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

async function openFilesPanel(page: Page) {
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(project));
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  await page.getByTestId("new-chat").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");
  await page.getByTestId("files-toggle").click();
  await expect(page.getByTestId("files-panel")).toBeVisible();
}

test("PART A: closing + reopening the Files tab restores the open file strip", async ({ page }) => {
  await openFilesPanel(page);

  // Open two files: hello.txt (in src/) and notes.txt (root).
  await page.locator('[data-testid="file-tree-dir"][data-path="src"]').click();
  const helloRow = page.locator('[data-testid="file-tree-file"][data-path="src/hello.txt"]');
  await expect(helloRow).toBeVisible({ timeout: 15_000 });
  await helloRow.click();
  await page.locator('[data-testid="file-tree-file"][data-path="notes.txt"]').click();

  // Both tabs are open; notes.txt is the active (last-opened) one.
  await expect(page.getByTestId("files-tab-0")).toHaveText(/hello\.txt/);
  await expect(page.getByTestId("files-tab-1")).toHaveText(/notes\.txt/);
  await expect(page.getByTestId("files-tab-1")).toHaveAttribute("data-active", "true");

  // Close the whole Files workspace tab — the panel unmounts.
  await page.getByTestId("workspace-tab-close-files").click();
  await expect(page.getByTestId("files-panel")).toHaveCount(0);

  // Reopen the Files tab: the open-file strip is RESTORED from the store (both
  // tabs, with notes.txt still active), not reset to an empty tree-only panel.
  await page.getByTestId("files-toggle").click();
  await expect(page.getByTestId("files-panel")).toBeVisible();
  await expect(page.getByTestId("files-tab-strip")).toBeVisible();
  await expect(page.getByTestId("files-tab-0")).toHaveText(/hello\.txt/);
  await expect(page.getByTestId("files-tab-1")).toHaveText(/notes\.txt/);
  await expect(page.getByTestId("files-tab-1")).toHaveAttribute("data-active", "true");
  // The restored active file refetched its content into the editor.
  await expect(page.locator('[data-testid="file-preview-text"]:visible')).toContainText(
    "first note",
    { timeout: 15_000 },
  );
});

test("PART B: editing a text file debounce-autosaves to disk (status chip → Saved)", async ({
  page,
}) => {
  await openFilesPanel(page);
  await page.locator('[data-testid="file-tree-dir"][data-path="src"]').click();
  const helloRow = page.locator('[data-testid="file-tree-file"][data-path="src/hello.txt"]');
  await expect(helloRow).toBeVisible({ timeout: 15_000 });
  await helloRow.click();

  const text = page.locator('[data-testid="file-preview-text"]:visible');
  await expect(text).toContainText("hello from the files panel", { timeout: 15_000 });
  // The text view is EDITABLE (contentEditable), not read-only.
  const content = text.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");

  // Type at the document end — an appended marker we can assert on disk.
  await content.click();
  await page.keyboard.press("Control+End");
  await page.keyboard.type("\n// autosave-marker-42");

  // The status chip shows Saved once the debounced write lands.
  const status = page.locator('[data-testid="file-save-status"]:visible');
  await expect(status).toHaveAttribute("data-status", "saved", { timeout: 15_000 });

  // The bytes on disk now include the marker (a real file_write happened).
  await expect
    .poll(() => readFileSync(path.join(project, "src", "hello.txt"), "utf8"), { timeout: 15_000 })
    .toContain("autosave-marker-42");
});

test("PART B: binary + truncated files stay read-only (no editing)", async ({ page }) => {
  await openFilesPanel(page);

  // A binary file degrades to the binary placeholder — no editor at all.
  await page.locator('[data-testid="file-tree-file"][data-path="data.bin"]').click();
  await expect(page.getByTestId("file-preview-binary")).toBeVisible({ timeout: 15_000 });
  // No editable save-status chip for a binary file.
  await expect(page.locator('[data-testid="file-save-status"]:visible')).toHaveCount(0);

  // A >1MB text file is TRUNCATED — shown but READ-ONLY (saving it would drop
  // the tail), so its CodeMirror content is not contentEditable.
  await page.locator('[data-testid="file-tree-file"][data-path="huge.txt"]').click();
  await expect(page.getByTestId("file-preview-notice")).toBeVisible({ timeout: 15_000 });
  const hugeContent = page.locator('[data-testid="file-preview-text"]:visible .cm-content');
  await expect(hugeContent).toHaveAttribute("contenteditable", "false");
  // No save-status chip for a read-only (truncated) file either.
  await expect(page.locator('[data-testid="file-save-status"]:visible')).toHaveCount(0);
});

test("PART B: an on-disk change between read and write surfaces a conflict", async ({ page }) => {
  await openFilesPanel(page);
  const notesRow = page.locator('[data-testid="file-tree-file"][data-path="notes.txt"]');
  await expect(notesRow).toBeVisible({ timeout: 15_000 });
  await notesRow.click();
  const text = page.locator('[data-testid="file-preview-text"]:visible');
  await expect(text).toContainText("first note", { timeout: 15_000 });

  // The pi agent (simulated) rewrites the file on disk AFTER the client read it,
  // so the client's captured base version is now stale.
  const external = "REWRITTEN BY THE AGENT\n";
  writeFileSync(path.join(project, "notes.txt"), external);

  // Now the user types — the debounced write carries the stale base version and
  // the server refuses it (conflict), keeping the buffer.
  const content = text.locator(".cm-content");
  await content.click();
  await page.keyboard.press("Control+End");
  await page.keyboard.type(" edited");

  const status = page.locator('[data-testid="file-save-status"]:visible');
  await expect(status).toHaveAttribute("data-status", "conflict", { timeout: 15_000 });
  // The user's buffer was NOT overwritten onto disk — the agent's content stands.
  expect(readFileSync(path.join(project, "notes.txt"), "utf8")).toBe(external);

  // The reload affordance refetches the on-disk version + content.
  await page.getByTestId("file-save-reload").click();
  await expect(page.locator('[data-testid="file-preview-text"]:visible')).toContainText(
    "REWRITTEN BY THE AGENT",
    { timeout: 15_000 },
  );
  await expect(page.locator('[data-testid="file-save-status"]:visible')).toHaveCount(0);
});
