import { mockMcpServerLaunch } from "@agent-deck/testkit";
import { expect, test } from "../helpers/fixtures.ts";
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

  // Remove it (confirm-gated, native parity) → the row disappears + empty state.
  page.once("dialog", (dialog) => void dialog.accept());
  await page.getByTestId("mcp-remove-mock").click();
  await expect(page.getByTestId("mcp-mock")).toHaveCount(0);
  await expect(page.getByTestId("mcp-empty")).toBeVisible();
});

test("signs in to an OAuth http server: open link, paste code, becomes authorized", async ({
  page,
}) => {
  // Script the MCP endpoints so the OAuth flow (needs-auth → login URL → callback
  // → authorized) is exercised hermetically, without a real MCP provider.
  let authorized = false;
  let callbackBody: { code?: string; state?: string } | undefined;

  await page.route("**/mcp", async (route) => {
    if (route.request().method() !== "GET") return route.fallback();
    await route.fulfill({
      status: 200,
      json: {
        servers: [
          {
            id: "authsrv",
            transport: "http",
            connected: authorized,
            toolNames: authorized ? ["mcp__authsrv__echo"] : [],
            auth: { status: authorized ? "authorized" : "unauthenticated" },
          },
        ],
      },
    });
  });
  await page.route("**/mcp/*/login", async (route) => {
    if (route.request().method() !== "POST") return route.fallback();
    await route.fulfill({
      status: 200,
      json: {
        auth: {
          status: "authorizing",
          authUrl: "https://auth.test/authorize?client_id=x&state=STATE123",
        },
      },
    });
  });
  await page.route("**/mcp/*/login/callback", async (route) => {
    callbackBody = route.request().postDataJSON() as { code?: string; state?: string };
    authorized = true;
    await route.fulfill({ status: 200, json: { auth: { status: "authorized" }, server: {} } });
  });

  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-mcp").click();

  // The http server shows sign-in required, and a Sign in button.
  await expect(page.getByTestId("mcp-auth-authsrv")).toHaveText("sign-in required");
  await page.getByTestId("mcp-login-authsrv").click();

  // The panel shows the authorization link to open.
  await expect(page.getByTestId("mcp-login-url-authsrv")).toHaveAttribute(
    "href",
    /auth\.test\/authorize/,
  );

  // Paste the code and connect → success toast + the badge flips to signed in.
  await page.getByTestId("mcp-login-code-authsrv").fill("browser-code");
  await page.getByTestId("mcp-login-submit-authsrv").click();
  await expect(page.getByTestId("toast")).toContainText(/Signed in to/);
  await expect(page.getByTestId("mcp-auth-authsrv")).toHaveText("signed in");

  // The UI parsed the OAuth state out of the authorization URL and echoed it back
  // with the code (CSRF round-trip).
  expect(callbackBody).toEqual({ code: "browser-code", state: "STATE123" });
});
