import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, selectProject, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Slice L1 gate: the tabbed workspace pane. The four right-side tools (diff /
 * files / preview / checkpoints) now open as TABS in ONE right pane with a
 * Chrome-style strip + "+" menu, instead of four side-by-side asides. This spec
 * pins the three behaviors the refactor is about:
 *   (1) opening two tools yields TWO tabs in ONE pane (not two stacked asides),
 *   (2) switching tabs is KEEP-ALIVE — switching away from the running preview
 *       and back keeps its live dev-server embed + local URL state (the inactive
 *       body is hidden with display:none, never unmounted),
 *   (3) the "+" menu opens a tool as a tab.
 *
 * The project runs a trivial static dev server (ephemeral loopback port) so the
 * preview tab has a real embedded iframe whose survival across a tab switch is
 * the keep-alive proof. Orphan hygiene mirrors preview.spec: the dev server is
 * owned by the RPC connection and afterAll's harness.close() sweeps it.
 */

const PROJECT = mkdtempSync(path.join(tmpdir(), "proj-workspace-tabs-"));

let harness: E2eHarness;

test.beforeAll(async () => {
  writeFileSync(
    path.join(PROJECT, "package.json"),
    JSON.stringify({ name: "tabs-fixture", private: true, scripts: { dev: "node server.js" } }),
  );
  writeFileSync(
    path.join(PROJECT, "server.js"),
    [
      "const http = require('node:http');",
      "const server = http.createServer((_req, res) => {",
      "  res.writeHead(200, { 'content-type': 'text/html' });",
      "  res.end('<!doctype html><html><body><h1>tabs</h1></body></html>');",
      "});",
      "server.listen(0, '127.0.0.1', () => {",
      "  process.stdout.write(`  Local:   http://localhost:${server.address().port}/\\n`);",
      "});",
      "process.on('SIGTERM', () => process.exit(0));",
      "",
    ].join("\n"),
  );

  harness = await startHarness({ reply: () => "ok", chunkDelayMs: 0 });
  const response = await fetch(`${harness.baseUrl}/projects`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ path: PROJECT }),
  });
  if (!response.ok) throw new Error(await response.text());
});

test.afterAll(async () => {
  await harness.close();
});

test("two tools share one tabbed pane, switching is keep-alive, and + opens a tab", async ({
  page,
}) => {
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(PROJECT));
  await expect(page.getByTestId("session-cwd")).toHaveText(PROJECT);
  await page.getByTestId("new-chat").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  // Open Preview and run the dev server; the discovered port embeds an iframe.
  await page.getByTestId("preview-toggle").click();
  await expect(page.getByTestId("workspace-tab-preview")).toBeVisible();
  await page.getByTestId("preview-run").click();
  const iframe = page.getByTestId("preview-iframe");
  await expect(iframe).toBeVisible({ timeout: 30_000 });
  const previewUrl = await page.getByTestId("preview-url-input").inputValue();
  expect(previewUrl).toMatch(/^http:\/\/localhost:\d+\/?$/);

  // Open Files too: now there are TWO tabs in ONE pane — not two stacked asides.
  await page.getByTestId("files-toggle").click();
  await expect(page.getByTestId("workspace-pane")).toHaveCount(1);
  await expect(page.getByTestId("workspace-tab-preview")).toBeVisible();
  await expect(page.getByTestId("workspace-tab-files")).toBeVisible();
  // Files just opened, so it is the active tab; its body renders.
  await expect(page.getByTestId("files-panel")).toBeVisible();

  // KEEP-ALIVE: the preview body is now hidden (display:none) but still MOUNTED —
  // the iframe stays in the DOM, so the live dev server is never torn down.
  await expect(iframe).toBeHidden();
  await expect(iframe).toHaveCount(1);

  // Switch back to the Preview tab: the SAME embed reappears with the SAME URL —
  // the running-server view and its component-local state survived the switch
  // (a remount would have reset it to the scripts runner).
  await page.getByTestId("workspace-tab-preview").click();
  await expect(iframe).toBeVisible();
  await expect(iframe).toHaveAttribute("src", previewUrl);
  await expect(page.getByTestId("preview-url-input")).toHaveValue(previewUrl);
  // Files is still open in the strip, just no longer active.
  await expect(page.getByTestId("workspace-tab-files")).toBeVisible();

  // The "+" menu opens another tool as a tab.
  await page.getByTestId("workspace-tab-add").click();
  await expect(page.getByTestId("workspace-add-menu")).toBeVisible();
  await page.getByTestId("workspace-add-checkpoints").click();
  await expect(page.getByTestId("workspace-add-menu")).toHaveCount(0);
  await expect(page.getByTestId("workspace-tab-checkpoints")).toBeVisible();
  await expect(page.getByTestId("checkpoints-panel")).toBeVisible();
  // Still exactly one pane hosting all three tabs.
  await expect(page.getByTestId("workspace-pane")).toHaveCount(1);

  // Reap the dev server: back to scripts on the preview tab, Stop it.
  await page.getByTestId("workspace-tab-preview").click();
  await page.getByTestId("preview-back").click();
  await expect(page.getByTestId("preview-stop")).toBeVisible();
  await page.getByTestId("preview-stop").click();
});
