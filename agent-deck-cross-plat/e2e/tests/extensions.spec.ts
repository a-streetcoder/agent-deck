import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "@playwright/test";
import { writeQuestionCommandExtension } from "@agent-deck/testkit";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Tier-3 gate (Extensions screen): a pi extension added through the screen
 * loads into new sessions (its registered command shows up via pi's
 * get_commands), and disabling it excludes it from the next session.
 */

let harness: E2eHarness;
const extFile = writeQuestionCommandExtension(); // registers an /ask-test command
const extName = path.basename(extFile);

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
});

test.afterAll(async () => {
  await harness.close();
});

async function sessionIds(): Promise<Set<string>> {
  const { sessions } = (await (await fetch(`${harness.baseUrl}/sessions`)).json()) as {
    sessions: Array<{ id: string }>;
  };
  return new Set(sessions.map((s) => s.id));
}

async function newSessionId(before: Set<string>): Promise<string> {
  const { sessions } = (await (await fetch(`${harness.baseUrl}/sessions`)).json()) as {
    sessions: Array<{ id: string }>;
  };
  return sessions.find((s) => !before.has(s.id))!.id;
}

async function commandNames(id: string): Promise<string[]> {
  const res = await fetch(`${harness.baseUrl}/sessions/${id}/commands`);
  if (!res.ok) return [];
  const { commands } = (await res.json()) as { commands: Array<{ name: string }> };
  return commands.map((c) => c.name);
}

test("adding an extension loads its command; disabling excludes it", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  // Add the extension via the screen.
  await page.getByTestId("nav-extensions").click();
  await page.getByTestId("extension-add").click();
  await page.getByTestId("extension-path").fill(extFile);
  await page.getByTestId("extension-add-confirm").click();
  await expect(page.locator(`[data-extension-name="${extName}"]`)).toBeVisible();

  // A new session now loads it → /ask-test is a registered command.
  const before1 = await sessionIds();
  await page.getByTestId("new-chat").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");
  const id1 = await newSessionId(before1);
  await expect.poll(() => commandNames(id1), { timeout: 20_000 }).toContain("ask-test");

  // Disable it → the next session excludes it.
  await page.getByTestId("nav-extensions").click();
  await page.getByTestId(`extension-toggle-${extName}`).click();
  const before2 = await sessionIds();
  await page.getByTestId("new-chat").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");
  const id2 = await newSessionId(before2);
  await expect.poll(() => commandNames(id2), { timeout: 20_000 }).not.toContain("ask-test");
});

test("flags two enabled extensions that share a filename (§16.2)", async ({ page }) => {
  // Same basename, different directories → pi would load a duplicate.
  const dupName = "dup-ext.ts";
  const a = path.join(mkdtempSync(path.join(tmpdir(), "ext-a-")), dupName);
  const b = path.join(mkdtempSync(path.join(tmpdir(), "ext-b-")), dupName);
  writeFileSync(a, "export default {};\n");
  writeFileSync(b, "export default {};\n");

  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-extensions").click();
  for (const p of [a, b]) {
    await page.getByTestId("extension-add").click();
    await page.getByTestId("extension-path").fill(p);
    await page.getByTestId("extension-add-confirm").click();
  }

  // Both same-named rows are flagged as conflicting.
  await expect(page.getByTestId("extension-conflict")).toHaveCount(2);

  // Disabling one resolves the conflict for both (only one is loaded now).
  await page.getByTestId(`extension-toggle-${dupName}`).first().click();
  await expect(page.getByTestId("extension-conflict")).toHaveCount(0);
});
