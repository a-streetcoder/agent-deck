import { expect, test } from "@playwright/test";
import type { SessionMeta } from "@agent-deck/domain";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Stage-G gate (session management parity): rename persists, fork duplicates
 * the transcript into an independent session, and delete removes it.
 */

let harness: E2eHarness;

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
});

test.afterAll(async () => {
  await harness.close();
});

async function liveSessions(): Promise<SessionMeta[]> {
  const { sessions } = (await (await fetch(`${harness.baseUrl}/sessions`)).json()) as {
    sessions: SessionMeta[];
  };
  return sessions;
}

test("rename a chat and see the new title persist", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");
  await page.getByTestId("composer-input").fill("first message");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("assistant-text")).toContainText("first message", {
    timeout: 30_000,
  });

  const id = (await liveSessions())[0]!.id;
  const row = page.getByTestId("chat-list").getByTestId(`chat-${id}`);
  await row.hover();
  await page.getByTestId("chat-list").getByTestId(`chat-rename-${id}`).click();
  const input = page.getByTestId("chat-list").getByTestId(`chat-rename-input-${id}`);
  await input.fill("Renamed chat");
  await input.press("Enter");

  await expect(page.getByTestId("chat-list").getByTestId(`chat-${id}`)).toContainText(
    "Renamed chat",
  );
  await expect
    .poll(async () => (await liveSessions()).find((s) => s.id === id)?.title)
    .toBe("Renamed chat");
});

test("fork duplicates the transcript into an independent session", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");
  await page.getByTestId("composer-input").fill("remember pineapple");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("assistant-text").last()).toContainText("pineapple", {
    timeout: 30_000,
  });
  // Fork is refused while responding — wait for the turn to finish.
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  const before = await liveSessions();
  const source = before[0]!;
  // Fork needs a captured pi session file — wait for it.
  await expect
    .poll(async () => (await liveSessions()).find((s) => s.id === source.id)?.piSessionFile)
    .toBeTruthy();

  const row = page.getByTestId("chat-list").getByTestId(`chat-${source.id}`);
  await row.hover();
  await page.getByTestId("chat-list").getByTestId(`chat-fork-${source.id}`).click();

  // A new session exists and it carries the forked transcript.
  await expect.poll(async () => (await liveSessions()).length).toBe(before.length + 1);
  await expect(page.getByTestId("user-cell").last()).toContainText("remember pineapple");
  await expect(page.getByTestId("assistant-text").last()).toContainText("pineapple");

  // The fork is independent: a follow-up in it streams normally.
  await page.getByTestId("composer-input").fill("still here?");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("assistant-text").last()).toContainText("still here?", {
    timeout: 30_000,
  });
});

test("delete removes a chat", async ({ page }) => {
  await page.goto(harness.baseUrl);
  // Make a fresh chat to delete.
  await page.getByTestId("new-chat").click();
  await page.getByTestId("composer-input").fill("delete me");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("assistant-text").last()).toContainText("delete me", {
    timeout: 30_000,
  });

  const target = (await liveSessions()).find((s) => s.title == null || s.title.includes("delete"));
  const id = target?.id ?? (await liveSessions()).at(-1)!.id;
  const row = page.getByTestId("chat-list").getByTestId(`chat-${id}`);
  await row.hover();
  await page.getByTestId("chat-list").getByTestId(`chat-delete-${id}`).click();

  await expect.poll(async () => (await liveSessions()).some((s) => s.id === id)).toBe(false);
  await expect(page.getByTestId("chat-list").getByTestId(`chat-${id}`)).toHaveCount(0);
});

// The id of the one session added since `before` (other tests share the server).
async function newSessionId(before: Set<string>): Promise<string> {
  const fresh = (await liveSessions()).filter((s) => !before.has(s.id));
  return fresh[0]!.id;
}

test("the most recently active session sorts to the top of the list", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  // Session A: create it explicitly and capture its id (prior tests leave
  // sessions in the shared server, so positional lookups aren't reliable).
  const beforeA = new Set((await liveSessions()).map((s) => s.id));
  await page.getByTestId("new-chat").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");
  await expect.poll(async () => (await liveSessions()).length).toBe(beforeA.size + 1);
  const idA = await newSessionId(beforeA);
  await page.getByTestId("composer-input").fill("message in A");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("assistant-text").last()).toContainText("message in A", {
    timeout: 30_000,
  });

  // Session B is created after A, so it starts on top of A.
  await page.getByTestId("new-chat").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  // Re-activating A (switch + prompt) must float it back above B.
  await page.getByTestId("chat-list").getByTestId(`chat-${idA}`).click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");
  await page.getByTestId("composer-input").fill("back in A");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("assistant-text").last()).toContainText("back in A", {
    timeout: 30_000,
  });

  const firstRow = page
    .getByTestId("chat-list")
    .locator('[data-testid^="chat-"][role="button"]')
    .first();
  await expect(firstRow).toHaveAttribute("data-testid", `chat-${idA}`);
});
