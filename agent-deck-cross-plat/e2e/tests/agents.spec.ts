import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Slice-8 gate: picking an agent launches an agent-backed session whose
 * system prompt IS the agent's markdown body — asserted from the mock
 * provider's captured request, i.e. what the model actually received.
 */

const AGENT_BODY = "You are pancake-bot. Answer every question with breakfast metaphors.";

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-agent-"));

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
  const agentsDir = path.join(project, ".pi", "agents");
  mkdirSync(agentsDir, { recursive: true });
  writeFileSync(
    path.join(agentsDir, "pancake-bot.md"),
    `---\nname: pancake-bot\ndescription: Breakfast metaphors only\n---\n\n${AGENT_BODY}\n`,
  );
  // A second agent in append mode (with an explicit extension allowlist) so the
  // detail's Prompt Mode + Extensions indicators are testable.
  writeFileSync(
    path.join(agentsDir, "append-bot.md"),
    `---\nname: append-bot\ndescription: Adds to pi's base prompt\nsystemPromptMode: append\nextensions:\n  - note-taker\n  - web-search\n---\n\nExtra instructions appended on top of pi's base prompt.\n`,
  );
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

test("picking an agent injects its body as the system prompt", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await expect(page.getByTestId("session-cwd")).toHaveText(project);

  // Pick the project agent in the composer.
  await page.getByTestId("agent-picker").selectOption("pancake-bot");
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  const requestCountBefore = harness.mock.requests.length;
  await page.getByTestId("composer-input").fill("what is a monad?");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("assistant-text")).toContainText("what is a monad?", {
    timeout: 30_000,
  });

  // The model request carries the agent body as (part of) the system prompt.
  const request = harness.mock.requests[requestCountBefore];
  expect(request).toBeDefined();
  const systemMessage = request!.messages.find(
    (m) => m.role === "system" || m.role === "developer",
  );
  expect(systemMessage).toBeDefined();
  expect(JSON.stringify(systemMessage!.content)).toContain(
    "You are pancake-bot. Answer every question with breakfast metaphors.",
  );

  // Switching back to the default agent restores a separate session.
  await page.getByTestId("agent-picker").selectOption("");
  await expect(page.getByTestId("user-cell")).toHaveCount(0);
  // And back again: the agent chat's transcript is still there.
  await page.getByTestId("agent-picker").selectOption("pancake-bot");
  await expect(page.getByTestId("user-cell")).toContainText("what is a monad?");
});

test("the agent detail surfaces the system-prompt mode and extensions (native parity)", async ({
  page,
}) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await page.getByTestId("nav-agents").click();

  // pancake-bot declares no mode → the default "replace"; like native, the badge
  // is hidden for the implicit default. It also declares no extensions.
  await page.locator('[data-agent-name="pancake-bot"]').click();
  await expect(page.getByTestId("agent-detail")).toBeVisible();
  await expect(page.getByTestId("agent-prompt-mode")).toHaveCount(0);
  await expect(page.getByTestId("agent-extensions")).toHaveCount(0);

  // append-bot declares systemPromptMode: append and an extension allowlist.
  await page.locator('[data-agent-name="append-bot"]').click();
  await expect(page.getByTestId("agent-prompt-mode")).toHaveText("append");
  const extensions = page.getByTestId("agent-extensions");
  await expect(extensions).toContainText("note-taker");
  await expect(extensions).toContainText("web-search");
});

test("an agent-bound session shows the agent name in the expanded panel (native paperplane line)", async ({
  page,
}) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await expect(page.getByTestId("session-cwd")).toHaveText(project);

  // Picking an agent binds the session to it (SessionMeta.agentName).
  await page.getByTestId("agent-picker").selectOption("pancake-bot");
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  // The expanded browsing list surfaces the bound agent's name as a visible line
  // (native paperplane row), not just the row's hover tooltip.
  await page.getByTestId("sessions-expand").click();
  const panel = page.getByTestId("sessions-expanded");
  await expect(panel).toHaveAttribute("aria-hidden", "false");
  await expect(panel.getByTestId("chat-agent-name").first()).toHaveText("pancake-bot");
});
