import { expect, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Phase-2 gate (native sidebar/session model): the pi agent is not a nav row,
 * and the sessions pull-up panel is one global expansion that persists while
 * you switch sessions — matching the Swift isCodingAgentPanelExpanded.
 */

let harness: E2eHarness;

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
});

test.afterAll(async () => {
  await harness.close();
});

test("no Pi Agent nav row — chat is reached through the sessions panel", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");
  // The removed nav button is gone; Projects/Agents/Skills remain.
  await expect(page.getByTestId("nav-chat")).toHaveCount(0);
  await expect(page.getByTestId("nav-projects")).toBeVisible();
});

test("the sessions panel stays expanded while switching sessions", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  // Two sessions so there's something to switch between.
  await page.getByTestId("composer-input").fill("first message");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("assistant-text")).toContainText("first message", {
    timeout: 30_000,
  });
  await page.getByTestId("new-chat").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  const panel = page.getByTestId("sessions-expanded");
  const rows = panel.locator('[data-testid^="chat-"][role="button"]');

  // Expand the panel.
  await page.getByTestId("sessions-expand").click();
  await expect(panel).toHaveAttribute("aria-hidden", "false");
  await expect(rows).toHaveCount(2);

  // Selecting a session inside the expanded panel must NOT collapse it.
  await rows.nth(1).click();
  await expect(panel).toHaveAttribute("aria-hidden", "false");
  await rows.nth(0).click();
  await expect(panel).toHaveAttribute("aria-hidden", "false");

  // The collapse chevron still collapses it.
  await page.getByTestId("sessions-collapse").click();
  await expect(panel).toHaveAttribute("aria-hidden", "true");
});

test("the panel remembers its expanded state across reloads", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");
  const panel = page.getByTestId("sessions-expanded");

  await page.getByTestId("sessions-expand").click();
  await expect(panel).toHaveAttribute("aria-hidden", "false");

  // The explicit expand persists — a fresh load opens the panel the same way.
  await page.reload();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");
  await expect(panel).toHaveAttribute("aria-hidden", "false");

  // Collapsing persists too.
  await page.getByTestId("sessions-collapse").click();
  await page.reload();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");
  await expect(panel).toHaveAttribute("aria-hidden", "true");
});

test("an untitled session shows a Draft · <project> display title", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");
  await page.getByTestId("new-chat").click();
  await expect(page.getByTestId("chat-list")).toContainText("Draft · All Projects");
});

test("the expanded panel filters sessions by title (18.1)", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  // Ensure at least two sessions exist.
  await page.getByTestId("new-chat").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");
  await page.getByTestId("new-chat").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  const panel = page.getByTestId("sessions-expanded");
  const rows = panel.locator('[data-testid^="chat-"][role="button"]');
  await page.getByTestId("sessions-expand").click();
  await expect(panel).toHaveAttribute("aria-hidden", "false");

  // Rename two rows to distinct titles (target by "not yet renamed" so a
  // reorder-on-rename can't make us rename the same row twice).
  const renameInput = panel.locator('[data-testid^="chat-rename-input-"]');
  const rename = async (rowLocator: ReturnType<typeof panel.locator>, name: string) => {
    await rowLocator.hover();
    await rowLocator.getByTitle("Rename").click();
    await renameInput.fill(name);
    await renameInput.press("Enter");
    await expect(panel.getByText(name, { exact: true })).toBeVisible();
  };
  await rename(rows.first(), "alpha-session");
  await rename(rows.filter({ hasNotText: "alpha-session" }).first(), "beta-session");

  // Search filters to the matching title; drafts don't match so the count is
  // deterministic regardless of how many other sessions exist.
  await page.getByTestId("sessions-search").fill("alpha");
  await expect(rows).toHaveCount(1);
  await expect(panel).toContainText("alpha-session");
  await expect(panel).not.toContainText("beta-session");

  // A non-matching query shows the empty state.
  await page.getByTestId("sessions-search").fill("zzz-no-such-session");
  await expect(rows).toHaveCount(0);
  await expect(page.getByTestId("sessions-search-empty")).toBeVisible();

  // Clearing the search restores the list (both renamed sessions present).
  await page.getByTestId("sessions-search").fill("");
  await expect(panel).toContainText("alpha-session");
  await expect(panel).toContainText("beta-session");
});

test("the expanded panel shows each session's last-active time (native row caption)", async ({
  page,
}) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  await page.getByTestId("new-chat").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  const panel = page.getByTestId("sessions-expanded");
  await page.getByTestId("sessions-expand").click();
  await expect(panel).toHaveAttribute("aria-hidden", "false");

  // Each expanded row renders a formatted last-active caption (locale/timezone
  // vary across CI runners, so assert a real date-time rather than an exact
  // string: it contains a digit and is non-empty).
  const timestamp = panel.getByTestId("chat-timestamp").first();
  await expect(timestamp).toBeVisible();
  await expect(timestamp).toHaveText(/\d/);
});

test("navigating to a nav section renders it with the panel collapsed", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  const panel = page.getByTestId("sessions-expanded");
  // Expand then collapse (nav is inert while the panel covers it), then a nav
  // pick both shows the section and leaves the panel down.
  await page.getByTestId("sessions-expand").click();
  await expect(panel).toHaveAttribute("aria-hidden", "false");
  await page.getByTestId("sessions-collapse").click();

  await page.getByTestId("nav-projects").click();
  await expect(page.getByTestId("projects-screen")).toBeVisible();
  await expect(panel).toHaveAttribute("aria-hidden", "true");
});
