import { mockMcpServerLaunch } from "@agent-deck/testkit";
import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * MCP screen (the visible half): the configured MCP servers list with live
 * connection status + their tools, and the refresh/remove actions. A stdio
 * server is seeded over REST (pointing at the testkit mock MCP server), then
 * driven through the UI.
 */

let harness: E2eHarness;

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
});

test.afterAll(async () => {
  await harness.close();
});

test("the empty state shows when no servers are configured", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-mcp").click();
  await expect(page.getByTestId("mcp-empty")).toBeVisible();
});

test("lists a configured MCP server as connected and removes it", async ({ page }) => {
  // Add a stdio MCP server over REST (the mock echo server subprocess).
  const launch = mockMcpServerLaunch("mock");
  const response = await fetch(`${harness.baseUrl}/mcp`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ name: "mock", command: launch.command, args: launch.args }),
  });
  expect(response.ok).toBe(true);

  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-mcp").click();

  const row = page.getByTestId("mcp-mock");
  await expect(row).toBeVisible();
  await expect(row).toHaveAttribute("data-connected", "true");
  await expect(page.getByTestId("mcp-status-mock")).toHaveText("connected");
  // The echo tool the mock server exposes is listed.
  await expect(row).toContainText("mcp__mock__echo");

  // Remove it → the row disappears and the empty state shows.
  await page.getByTestId("mcp-remove-mock").click();
  await expect(page.getByTestId("mcp-mock")).toHaveCount(0);
  await expect(page.getByTestId("mcp-empty")).toBeVisible();
});
