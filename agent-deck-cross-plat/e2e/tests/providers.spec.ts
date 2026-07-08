import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Providers screen (native provider-login surface, read + logout half): lists
 * the OAuth-capable providers pi knows about with their sign-in status read from
 * the global ~/.pi/agent/auth.json, and disconnects a stored credential.
 */

let harness: E2eHarness;

function authPath(): string {
  return path.join(harness.piHome, ".pi", "agent", "auth.json");
}
function seedOAuth(providerId: string): void {
  mkdirSync(path.dirname(authPath()), { recursive: true });
  writeFileSync(
    authPath(),
    JSON.stringify({
      [providerId]: { type: "oauth", refresh: "r", access: "a", expires: 4102444800000 },
    }),
  );
}

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
});

test.afterAll(async () => {
  await harness.close();
});

test("lists providers, reflects a seeded sign-in, and logs out", async ({ page }) => {
  // Discover a real provider id from the running server (built-ins are stable,
  // but don't hard-code the set).
  const res = await fetch(`${harness.baseUrl}/runtime/providers`);
  const { providers } = (await res.json()) as { providers: Array<{ id: string }> };
  const first = providers[0];
  expect(first).toBeDefined();
  const id = first!.id;

  // Fresh home → nothing signed in.
  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-providers").click();
  const row = page.locator(`[data-provider-id="${id}"]`);
  await expect(row).toBeVisible();
  await expect(row).toHaveAttribute("data-signed-in", "false");
  await expect(page.getByTestId(`provider-status-${id}`)).toHaveText("Not connected");

  // Seed a stored OAuth credential → the row flips to Signed in with a Log out.
  seedOAuth(id);
  await page.getByTestId("nav-environment").click(); // leave + return to force a reload
  await page.getByTestId("nav-providers").click();
  await expect(row).toHaveAttribute("data-signed-in", "true");
  await expect(page.getByTestId(`provider-status-${id}`)).toHaveText("Signed in");
  expect(JSON.parse(readFileSync(authPath(), "utf8"))).toHaveProperty(id);

  // Log out (confirm-gated, native parity) → the stored credential is removed.
  page.once("dialog", (dialog) => void dialog.accept());
  await page.getByTestId(`provider-logout-${id}`).click();
  await expect(row).toHaveAttribute("data-signed-in", "false");
  await expect(page.getByTestId(`provider-logout-${id}`)).toHaveCount(0);
  // auth.json no longer carries the credential (file may be pruned to {} or removed).
  const after = existsSync(authPath()) ? JSON.parse(readFileSync(authPath(), "utf8")) : {};
  expect(after).not.toHaveProperty(id);

  rmSync(authPath(), { force: true });
});

test("renders native provider logos (and a monogram fallback for unknowns)", async ({ page }) => {
  await page.route("**/runtime/providers", async (route) => {
    await route.fulfill({
      status: 200,
      json: {
        providers: [
          { id: "anthropic", name: "Anthropic", signedIn: false, configured: true },
          { id: "openai", name: "OpenAI", signedIn: false, configured: true },
          { id: "github-copilot", name: "GitHub Copilot", signedIn: false, configured: true },
          { id: "acme-unknown", name: "Acme", signedIn: false, configured: true },
        ],
      },
    });
  });

  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-providers").click();

  // Real brand logos render as inline SVGs (anthropic → the claude mark).
  const anthropic = page.getByTestId("provider-logo-anthropic");
  await expect(anthropic).toHaveAttribute("data-logo", "claude");
  await expect(anthropic.locator("svg path").first()).toBeVisible();
  await expect(page.getByTestId("provider-logo-openai")).toHaveAttribute("data-logo", "openai");
  await expect(page.getByTestId("provider-logo-github-copilot")).toHaveAttribute(
    "data-logo",
    "copilot",
  );
  // An unknown provider falls back to a monogram tile.
  await expect(page.getByTestId("provider-logo-acme-unknown")).toHaveAttribute(
    "data-logo",
    "fallback",
  );
});
