import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, selectProject, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Slice 16 gate: pointing out an element in the S15 preview becomes a pending
 * composer "element context" card and, on the next send, rides ONE prompt turn
 * to pi as the donor's serialized `<element_context>` block. Real stack: a
 * scratch project runs its static dev server (server-spawned managed child,
 * Effect-RPC script ops), whose loopback URL the server detects and embeds; the
 * preview's "Add element context" form captures a selector + note (our
 * sandboxed-iframe manual subset of the donor's in-frame inspector), the
 * composer shows the pending card, and a send delivers it — the mock provider's
 * captured request carries the serialized `<element_context>` block and the
 * pending set is cleared.
 *
 * Orphan hygiene: the dev server is owned by the RPC connection server-side; the
 * test stops it explicitly and afterAll's harness.close() runs the scriptRunner
 * closeAll() sweep (tree-kill) as a backstop.
 */

const PROJECT = mkdtempSync(path.join(tmpdir(), "proj-preview-auto-"));

let harness: E2eHarness;

test.beforeAll(async () => {
  writeFileSync(
    path.join(PROJECT, "package.json"),
    JSON.stringify({
      name: "preview-auto-fixture",
      private: true,
      scripts: { dev: "node server.js" },
    }),
  );
  writeFileSync(
    path.join(PROJECT, "server.js"),
    [
      "const http = require('node:http');",
      "const server = http.createServer((_req, res) => {",
      "  res.writeHead(200, { 'content-type': 'text/html' });",
      "  res.end('<!doctype html><html><body><button class=\"primary\">Save</button></body></html>');",
      "});",
      "server.listen(0, '127.0.0.1', () => {",
      "  process.stdout.write(`  Local:   http://localhost:${server.address().port}/\\n`);",
      "});",
      "process.on('SIGTERM', () => process.exit(0));",
      "",
    ].join("\n"),
  );

  harness = await startHarness({ reply: () => "On it.", chunkDelayMs: 0 });
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

test("an element context captured in the preview rides the next prompt to pi", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(PROJECT));
  await expect(page.getByTestId("session-cwd")).toHaveText(PROJECT);
  await page.getByTestId("new-chat").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  // A warmup turn establishes the live session (matches the review-comments gate,
  // where a first turn runs before the context-carrying send) so the element
  // send below is a follow-up turn, not the fresh-session first send.
  await page.getByTestId("composer-input").fill("hello");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("assistant-text")).toContainText("On it.", { timeout: 60_000 });
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle", {
    timeout: 60_000,
  });

  // Open the preview panel and run the dev server; the discovered port embeds.
  await page.getByTestId("preview-toggle").click();
  await expect(page.getByTestId("preview-panel")).toBeVisible();
  await page.getByTestId("preview-run").click();
  const iframe = page.getByTestId("preview-iframe");
  await expect(iframe).toBeVisible({ timeout: 30_000 });
  const previewUrl = await page.getByTestId("preview-url-input").inputValue();
  expect(previewUrl).toMatch(/^http:\/\/localhost:\d+\/?$/);

  // Enter element-capture mode and name the element (selector + note). The
  // sandboxed cross-origin iframe forbids in-frame pointing, so this is the
  // manual capture — the current preview URL rides along automatically.
  await page.getByTestId("preview-select-element").click();
  await expect(page.getByTestId("preview-element-form")).toBeVisible();
  await page.getByTestId("preview-element-selector").fill("button.primary");
  await page.getByTestId("preview-element-note").fill("Make the Save button larger.");
  await page.getByTestId("preview-element-add").click();

  // The form closes and one pending element card appears in the composer.
  await expect(page.getByTestId("preview-element-form")).toHaveCount(0);
  const card = page.getByTestId("pending-element-card");
  await expect(card).toHaveCount(1);
  await expect(card).toContainText("<button>");

  const requestsBefore = harness.mock.requests.length;

  // Send with a message: the pending element context serializes onto this turn.
  await page.getByTestId("composer-input").fill("Address my preview note.");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle", {
    timeout: 60_000,
  });

  // The pending set is cleared by the send.
  await expect(page.getByTestId("pending-element-card")).toHaveCount(0);

  // The prompt pi received (captured by the mock provider) carries the
  // serialized <element_context> block for the named element, verbatim.
  const newRequests = harness.mock.requests.slice(requestsBefore);
  const userText = newRequests
    .flatMap((request) => request.messages.filter((m) => m.role === "user"))
    .map((m) =>
      typeof m.content === "string"
        ? m.content
        : Array.isArray(m.content)
          ? m.content
              .map((part) =>
                typeof part === "object" && part !== null && "text" in part
                  ? String((part as { text: unknown }).text)
                  : "",
              )
              .join("")
          : "",
    )
    .join("\n");

  expect(userText).toContain("Address my preview note.");
  expect(userText).toContain("<element_context>");
  expect(userText).toContain("- <button>:");
  expect(userText).toContain(`  url: ${previewUrl}`);
  expect(userText).toContain("  selector: button.primary");
  expect(userText).toContain("  note: Make the Save button larger.");

  // Reap the dev server: back to scripts, Stop, assert the URL goes unreachable.
  await page.getByTestId("preview-back").click();
  await expect(page.getByTestId("preview-stop")).toBeVisible();
  await page.getByTestId("preview-stop").click();
  await expect.poll(() => isUnreachable(previewUrl), { timeout: 15_000 }).toBe(true);
});
