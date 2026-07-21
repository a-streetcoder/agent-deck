import { expect, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Command palette + user keybindings (Slice 14). The palette opens on the
 * rebindable Ctrl/⌘+K chord, fuzzy-filters commands, and runs the selection;
 * the keybindings editor rebinds a command live (store update → the same global
 * handler picks it up) and persists to the settings store.
 */

let harness: E2eHarness;

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
});

test.afterAll(async () => {
  await harness.close();
});

test("opens on ⌘K, filters to a nav command, and runs it", async ({ page }) => {
  await page.goto(harness.baseUrl);
  const palette = page.getByTestId("command-palette");

  await page.keyboard.press("ControlOrMeta+k");
  await expect(palette).toBeVisible();

  await page.getByTestId("command-palette-input").fill("skills");
  // The top match is "Go to Skills"; Enter runs it and navigates.
  await expect(page.getByTestId("command-palette-item").first()).toContainText("Skills");
  await page.keyboard.press("Enter");

  await expect(palette).toHaveCount(0);
  await expect(page.getByTestId("app-view-title")).toHaveText("Skills");
});

test("closes on Escape without running anything", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.keyboard.press("ControlOrMeta+k");
  await expect(page.getByTestId("command-palette")).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByTestId("command-palette")).toHaveCount(0);
  // Still on the default chat surface — nothing fired.
  await expect(page.getByTestId("chat-layer")).toHaveAttribute("aria-hidden", "false");
});

test("rebinds a command live through the editor", async ({ page }) => {
  await page.goto(harness.baseUrl);

  // Open the editor via the palette.
  await page.keyboard.press("ControlOrMeta+k");
  await page.getByTestId("command-palette-input").fill("keybind");
  await page.keyboard.press("Enter");
  const editor = page.getByTestId("keybindings-editor");
  await expect(editor).toBeVisible();

  // "Go to Git" ships without a chord — bind it and confirm the row updates.
  const gitRow = page.locator('[data-testid="keybindings-editor-row"][data-command="view.git"]');
  const gitChord = gitRow.getByTestId("keybindings-editor-chord");
  await expect(gitChord).toHaveText("Unassigned");
  await gitChord.click();
  await expect(gitChord).toHaveAttribute("data-capturing", "true");
  await page.keyboard.press("Control+Alt+g");
  await expect(gitChord).toHaveAttribute("data-overridden", "true");
  await expect(gitChord).toContainText("G");

  // Close the editor; the newly-bound chord now navigates.
  await page.getByTestId("keybindings-editor-close").click();
  await expect(editor).toHaveCount(0);
  await page.keyboard.press("Control+Alt+g");
  await expect(page.getByTestId("app-view-title")).toHaveText("Git");

  // The override persisted to the settings store.
  const response = await fetch(`${harness.baseUrl}/settings`);
  const data = (await response.json()) as {
    settings: { keybindings: Array<{ command: string; key: string }> };
  };
  expect(data.settings.keybindings).toContainEqual({ command: "view.git", key: "mod+alt+g" });
});
