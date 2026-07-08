import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Provider login sheet (native PiProviderLoginService), UI half. The login HTTP
 * endpoints are scripted with page.route so the interactive flow (device code →
 * prompt → done) is exercised hermetically, without a real OAuth provider. The
 * relay state machine itself is covered by the resources unit test.
 */

let harness: E2eHarness;

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
});

test.afterAll(async () => {
  await harness.close();
});

test("signing in shows the device code, accepts a code, and reports success", async ({ page }) => {
  const { providers } = (await (await fetch(`${harness.baseUrl}/runtime/providers`)).json()) as {
    providers: Array<{ id: string }>;
  };
  const id = providers[0]!.id;

  // Script the login flow: start → poll (device_code + prompt) → respond → poll (done).
  await page.route("**/runtime/providers/*/login", async (route) => {
    await route.fulfill({ status: 201, json: { loginId: "test-login" } });
  });
  await page.route("**/runtime/providers/login/*", async (route) => {
    const since = Number(new URL(route.request().url()).searchParams.get("since") ?? "0");
    const body =
      since === 0
        ? {
            events: [
              {
                type: "device_code",
                userCode: "WXYZ-1234",
                verificationUri: "https://ex.test/dev",
              },
              { type: "prompt", message: "Paste the code shown in your browser" },
            ],
            status: "running",
            nextCursor: 2,
          }
        : { events: [{ type: "done", ok: true }], status: "done", nextCursor: 3 };
    await route.fulfill({ status: 200, json: body });
  });
  await page.route("**/runtime/providers/login/*/respond", async (route) => {
    await route.fulfill({ status: 200, json: { ok: true } });
  });

  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-providers").click();
  await page.getByTestId(`provider-login-${id}`).click();

  // The sheet opens and shows the device code + a prompt.
  await expect(page.getByTestId("provider-login-sheet")).toBeVisible();
  await expect(page.getByTestId("login-device-code")).toHaveText("WXYZ-1234");
  await expect(page.getByTestId("login-auth-url")).toHaveCount(0);

  // Answer the prompt → the flow completes with success + a toast.
  await page.getByTestId("login-prompt-input").fill("hunter2");
  await page.getByTestId("login-prompt-submit").click();
  await expect(page.getByTestId("login-done")).toContainText("Signed in");
  await expect(page.getByTestId("toast")).toContainText(/Signed in to/);
});
