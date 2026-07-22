import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, selectProject, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Slice 15b gate: the dev-server preview panel against the REAL stack — a scratch
 * project with a trivial static dev-server script (a node http server serving a
 * fixed HTML string on an ephemeral loopback port), run through the Scripts
 * control (server-spawned managed child, Effect-RPC script ops over `/rpc`),
 * whose printed loopback URL the server detects + confirms and pushes back so the
 * panel embeds it in an iframe.
 *
 * Covers the panel contract end-to-end: the declared script is listed and
 * started, its output streams, the discovered port opens an embedded preview
 * whose iframe src IS the loopback URL, the served content is reachable (asserted
 * via a fetch — a cross-origin frame's body can't be read from the page), and
 * stopping the run tree-kills the child (the served URL becomes unreachable).
 *
 * Orphan hygiene: every started dev server is owned by the RPC connection
 * server-side; the test stops it explicitly and asserts death, and afterAll's
 * harness.close() runs the scriptRunner closeAll() sweep (tree-kill) as a backstop.
 */

const SENTINEL = "preview-fixture-page";

// A scratch project whose only script is a static dev server. server.js listens
// on an EPHEMERAL loopback port (so parallel runs never collide), prints its URL
// (the server-side port detector reads it from stdout), and serves a fixed page.
const PROJECT = mkdtempSync(path.join(tmpdir(), "proj-preview-"));

let harness: E2eHarness;

test.beforeAll(async () => {
  writeFileSync(
    path.join(PROJECT, "package.json"),
    JSON.stringify({ name: "preview-fixture", private: true, scripts: { dev: "node server.js" } }),
  );
  writeFileSync(
    path.join(PROJECT, "server.js"),
    [
      "const http = require('node:http');",
      "const server = http.createServer((_req, res) => {",
      "  res.writeHead(200, { 'content-type': 'text/html' });",
      `  res.end('<!doctype html><html><body><h1 id="sentinel">${SENTINEL}</h1></body></html>');`,
      "});",
      "server.listen(0, '127.0.0.1', () => {",
      "  const { port } = server.address();",
      "  process.stdout.write(`  Local:   http://localhost:${port}/\\n`);",
      "});",
      // Exit promptly on the tree-kill signal so the reap is observable.
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

/** True once a GET to `url` fails to connect (the dev server is gone). */
async function isUnreachable(url: string): Promise<boolean> {
  try {
    await fetch(url);
    return false;
  } catch {
    return true;
  }
}

test("scripts control runs a dev server, the discovered port embeds, stop reaps it", async ({
  page,
}) => {
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(PROJECT));
  await expect(page.getByTestId("session-cwd")).toHaveText(PROJECT);
  await page.getByTestId("new-chat").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  // Open the preview panel; the server lists the project's package.json scripts.
  await page.getByTestId("preview-toggle").click();
  const panel = page.getByTestId("preview-panel");
  await expect(panel).toBeVisible();

  const select = page.getByTestId("preview-script-select");
  // The `dev` script is listed and preselected (preferredScript picks it).
  await expect(select.locator("option", { hasText: "dev" })).toHaveCount(1);
  await expect(select).toHaveValue("dev");

  // Run it: the printed loopback port is detected + confirmed, so the panel
  // auto-embeds it (no user action) — the run's output streams into the log
  // first, but the embed can flip the view to the browser before we observe it,
  // so wait on the iframe (which proves run → discover → embed all happened).
  await page.getByTestId("preview-run").click();

  const iframe = page.getByTestId("preview-iframe");
  await expect(iframe).toBeVisible({ timeout: 30_000 });

  // The embedded URL is a normalized loopback origin, and the iframe points at it.
  const url = await page.getByTestId("preview-url-input").inputValue();
  expect(url).toMatch(/^http:\/\/localhost:\d+\/?$/);
  await expect(iframe).toHaveAttribute("src", url);

  // The served content is reachable at that URL (a cross-origin frame body can't
  // be read from the page, so assert the src above + fetch the URL here).
  const served = await fetch(url).then((response) => response.text());
  expect(served).toContain(SENTINEL);

  // Back to the scripts view, then Stop: the tree-kill takes the dev server down.
  await page.getByTestId("preview-back").click();
  await expect(page.getByTestId("preview-stop")).toBeVisible();
  await page.getByTestId("preview-stop").click();

  // The child process is dead: the served URL stops accepting connections.
  await expect.poll(() => isUnreachable(url), { timeout: 15_000 }).toBe(true);
  // The Run control is back (a fresh run can start).
  await expect(page.getByTestId("preview-run")).toBeVisible();
});

test("the preview panel lists nothing to run for a scriptless session", async ({ page }) => {
  await page.goto(harness.baseUrl);
  // The default (no-project) session runs in a hermetic temp cwd with no
  // package.json: the panel opens but has no scripts to run.
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");
  await page.getByTestId("preview-toggle").click();
  await expect(page.getByTestId("preview-panel")).toBeVisible();
  await expect(page.getByTestId("preview-empty")).toBeVisible();
  await expect(page.getByTestId("preview-run")).toBeDisabled();
});
