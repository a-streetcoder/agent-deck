import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "../helpers/fixtures.ts";
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

test("shows a discovered extension with its source label + a bridge-conflict warning", async ({
  page,
}) => {
  // Script the list so it returns a discovered extension and a bridge-conflicting
  // one, exercising the discovery UI without touching the real filesystem scan.
  await page.route("**/resources/extensions*", async (route) => {
    if (route.request().method() !== "GET") return route.fallback();
    await route.fulfill({
      status: 200,
      json: {
        extensions: [
          {
            path: "/proj/.pi/extensions/logger.ts",
            name: "logger.ts",
            exists: true,
            disabled: false,
            scope: "project",
            source: "discovered",
            bridgeConflict: null,
          },
          {
            path: "/proj/.pi/extensions/rogue.ts",
            name: "rogue.ts",
            exists: true,
            disabled: false,
            scope: "project",
            source: "discovered",
            bridgeConflict: "agent_deck_memory_write",
          },
        ],
      },
    });
  });

  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-extensions").click();

  // The discovered extension is labeled by scope + source, and (being discovered,
  // not added) has no Remove button.
  await expect(page.getByTestId("extension-source-logger.ts")).toHaveText("project · discovered");
  await expect(page.getByTestId("extension-remove-logger.ts")).toHaveCount(0);

  // The bridge-conflicting one is flagged as shadowed.
  await expect(page.getByTestId("extension-bridge-conflict-rogue.ts")).toBeVisible();
});

test("shows the read-only Agent Deck bridges inventory (memory active)", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-extensions").click();

  // The app-bridges section lists what Agent Deck injects over its own bridge.
  await expect(page.getByTestId("app-bridges")).toBeVisible();
  await expect(page.getByTestId("bridge-memory")).toBeVisible();
  await expect(page.getByTestId("bridge-state-memory")).toHaveText("active");
  await expect(page.getByTestId("bridge-memory")).toContainText("agent_deck_memory_write");
  // Deck-agents bridge is always on; MCP is off with no server configured.
  await expect(page.getByTestId("bridge-state-deck_agents")).toHaveText("active");
  await expect(page.getByTestId("bridge-state-mcp")).toHaveText("off");
});

test("loading-mode picker + bulk enable/disable (native PiAgentExtensionLoadingMode)", async ({
  page,
}) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-extensions").click();

  // The mode picker offers both native modes.
  await expect(page.getByTestId("extension-mode-useMyExtensions")).toBeVisible();
  await expect(page.getByTestId("extension-mode-agentDeckManaged")).toBeVisible();

  // Bulk enable flips the extension (left disabled by the first test) to enabled;
  // bulk disable flips it back.
  await page.getByTestId("extension-enable-all").click();
  await expect(page.getByTestId(`extension-toggle-${extName}`)).toContainText("Disable");
  await page.getByTestId("extension-disable-all").click();
  await expect(page.getByTestId(`extension-toggle-${extName}`)).toContainText("Enable");

  // Managed mode hides the bulk actions (user extensions stay off); restore the
  // default so the setting is left as "use my extensions".
  await page.getByTestId("extension-mode-agentDeckManaged").click();
  await expect(page.getByTestId("extension-mode-agentDeckManaged")).toHaveAttribute(
    "data-active",
    "true",
  );
  await expect(page.getByTestId("extension-enable-all")).toHaveCount(0);
  await page.getByTestId("extension-mode-useMyExtensions").click();
  await expect(page.getByTestId("extension-enable-all")).toBeVisible();
});
