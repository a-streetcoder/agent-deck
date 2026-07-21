import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, selectProject, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Slice 12 gate: review comments on diff lines flow into the composer as pending
 * cards and, on the next send, ride ONE prompt turn to pi as the donor's
 * serialized `<review_comment>` blocks. Real stack: a real pi turn writes a file
 * into a real git repo, the diff panel renders its lines, two comments are added
 * on two lines, the composer shows both cards, and a send delivers them — the
 * mock provider's captured request carries the serialized comments and the
 * pending set is cleared.
 */

let harness: E2eHarness;
const repo = mkdtempSync(path.join(tmpdir(), "proj-review-repo-"));
const FILE = path.join(repo, "src", "feature.txt");
const CONTENT = "alpha line\nbeta line\ngamma line\n";

test.beforeAll(async () => {
  const git = (args: string[]): void => {
    execFileSync("git", args, { cwd: repo, stdio: "ignore" });
  };
  git(["init", "-b", "main"]);
  git(["config", "user.email", "t@example.com"]);
  git(["config", "user.name", "Test"]);
  writeFileSync(path.join(repo, "README.md"), "# scratch\n");
  git(["add", "-A"]);
  git(["commit", "-m", "init"]);

  harness = await startHarness({
    chunkDelayMs: 20,
    reply: () => "Done.",
    // The "write the file" turn drives pi's real `write` tool once; every other
    // turn (including the review-comment send) answers with plain text.
    toolCall: (lastUser, body) => {
      const lastUserIndex = body.messages.map((m) => m.role).lastIndexOf("user");
      const toolRanThisTurn = body.messages.slice(lastUserIndex + 1).some((m) => m.role === "tool");
      if (toolRanThisTurn) return null;
      if (lastUser.includes("write the feature file")) {
        return { name: "write", arguments: { path: FILE, content: CONTENT } };
      }
      return null;
    },
  });
  const response = await fetch(`${harness.baseUrl}/projects`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ path: repo }),
  });
  if (!response.ok) throw new Error(await response.text());
});

test.afterAll(async () => {
  await harness.close();
});

test("comments on diff lines become pending cards and ride the next prompt to pi", async ({
  page,
}) => {
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(repo));
  await expect(page.getByTestId("session-cwd")).toHaveText(repo);
  await page.getByTestId("new-chat").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  // One turn writes the file; the turn boundary badges the changed set.
  await page.getByTestId("composer-input").fill("please write the feature file");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle", {
    timeout: 60_000,
  });
  await expect(page.getByTestId("diff-badge")).toHaveText("1", { timeout: 30_000 });

  // Open the panel and the file's diff.
  await page.getByTestId("diff-toggle").click();
  await page.locator('[data-testid="diff-tree-file"][data-path="src/feature.txt"]').click();
  await expect(page.getByTestId("diff-file-view")).toBeVisible();
  await expect(page.getByTestId("diff-lines")).toContainText("+alpha line", { timeout: 15_000 });

  // Add a comment on the first added line ("+alpha line").
  const alphaRow = page.locator('[data-testid="diff-line"]', { hasText: "alpha line" });
  await alphaRow.hover();
  await alphaRow.getByTestId("diff-comment-add").click();
  await page.getByTestId("diff-comment-input").fill("Please rename alpha to first.");
  await page.getByTestId("diff-comment-save").click();
  // The inline card appears under the row; the composer shows one pending card.
  await expect(page.getByTestId("diff-inline-comment")).toContainText("Please rename alpha");
  await expect(page.getByTestId("pending-comment-card")).toHaveCount(1);

  // Add a second comment on "+gamma line".
  const gammaRow = page.locator('[data-testid="diff-line"]', { hasText: "gamma line" });
  await gammaRow.hover();
  await gammaRow.getByTestId("diff-comment-add").click();
  await page.getByTestId("diff-comment-input").fill("Gamma needs a test.");
  await page.getByTestId("diff-comment-save").click();
  await expect(page.getByTestId("pending-comment-card")).toHaveCount(2);

  const requestsBefore = harness.mock.requests.length;

  // Send with a message: the pending comments serialize onto this one turn.
  await page.getByTestId("composer-input").fill("Address my review comments.");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle", {
    timeout: 60_000,
  });

  // The pending set is cleared by the send.
  await expect(page.getByTestId("pending-comment-card")).toHaveCount(0);

  // The prompt pi received (captured by the mock provider) carries the
  // serialized <review_comment> blocks for both lines, verbatim.
  const newRequests = harness.mock.requests.slice(requestsBefore);
  const userText = newRequests
    .flatMap((request) => request.messages.filter((m) => m.role === "user"))
    .map((m) =>
      typeof m.content === "string"
        ? m.content
        : Array.isArray(m.content)
          ? m.content
              .map((part) =>
                typeof part === "object" && part !== null && "text" in part
                  ? String((part as { text: unknown }).text)
                  : "",
              )
              .join("")
          : "",
    )
    .join("\n");

  expect(userText).toContain("Address my review comments.");
  expect(userText).toContain("<review_comment");
  expect(userText).toContain('filePath="src/feature.txt"');
  expect(userText).toContain("Please rename alpha to first.");
  expect(userText).toContain("Gamma needs a test.");
  // The synthesized single-line diff excerpts for each anchored line.
  expect(userText).toContain("+alpha line");
  expect(userText).toContain("+gamma line");
});
