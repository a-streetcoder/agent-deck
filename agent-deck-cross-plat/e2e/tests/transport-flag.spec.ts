import { expect, test, type Page } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * The transport at the browser boundary (Slice 7c): the web app speaks the
 * Effect-RPC `/rpc` transport as its SOLE socket path — the legacy `/ws` envelope
 * and its selection flag were retired. We capture the actual WebSocket the page
 * opens (the ground truth of which transport is live) and confirm a turn streams.
 */

const REPLY = "Transport check: this reply streams so the transport is exercised end to end.";

let harness: E2eHarness;

test.beforeAll(async () => {
  harness = await startHarness({ reply: () => REPLY, chunkDelayMs: 60 });
});

test.afterAll(async () => {
  await harness.close();
});

/** The path of the FIRST session WebSocket the page opens (must be "/rpc"). */
async function firstSocketPath(page: Page, url: string): Promise<string> {
  const socketUrl = new Promise<string>((resolve) => {
    page.on("websocket", (ws) => {
      const path = new URL(ws.url()).pathname;
      if (path === "/rpc") resolve(path);
    });
  });
  await page.goto(url);
  return socketUrl;
}

test("uses the /rpc transport and streams", async ({ page }) => {
  const path = await firstSocketPath(page, harness.baseUrl);
  expect(path).toBe("/rpc");

  await page.getByTestId("composer-input").fill("hello");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("assistant-text")).toContainText("streams", { timeout: 30_000 });
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle", {
    timeout: 30_000,
  });
});
