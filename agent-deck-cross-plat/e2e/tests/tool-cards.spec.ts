import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, selectProject, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Tool cards (native PiAgentTranscriptNativeToolGroup): a tool call renders with
 * a FRIENDLY name + a distinct icon instead of the raw tool name. Driven by the
 * mock provider making real pi call its built-in `read` tool.
 */

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-toolcard-"));
const notesPath = path.join(project, "notes.txt");

test.beforeAll(async () => {
  writeFileSync(notesPath, "the answer is 42\n");
  harness = await startHarness({
    chunkDelayMs: 20,
    reply: () => "Read the notes for you.",
    // First turn: make pi call `read`. After the tool result comes back
    // (a role:"tool" message), answer with text so it doesn't loop.
    toolCall: (_lastUser, body) =>
      body.messages.some((m) => m.role === "tool")
        ? null
        : { name: "read", arguments: { file_path: notesPath } },
  });
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

test("a read tool renders as a friendly 'Read' card with the file path", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(project));
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  await page.getByTestId("new-chat").click();

  await page.getByTestId("composer-input").fill("read the notes file");
  await page.getByTestId("send-button").click();

  // The tool cell carries the raw tool name for wiring but shows the friendly one.
  const toolCard = page.locator('[data-tool="read"]');
  await expect(toolCard).toBeVisible({ timeout: 30_000 });
  await expect(toolCard).toContainText("Read"); // friendly name, not "read"

  // The card auto-expands while running, surfacing the acted-on file path.
  await expect(toolCard.getByTestId("tool-file-path")).toContainText("notes.txt", {
    timeout: 15_000,
  });
});
