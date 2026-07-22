import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, selectProject, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Slice 18b gate — the DEFINITIVE checkpoint-rollback test against the REAL stack
 * (real pi, real git repo). Two real turns each write a file via pi's `write`
 * tool; then a rollback to turn 1 through the rewind UI must:
 *   (i)   remove turn 2's file from the worktree (uncommitted work discarded),
 *   (ii)  keep turn 1's file,
 *   (iii) truncate the CONVERSATION to turn 1 (turn-2 messages gone).
 *
 * (iii) is the end-to-end guard for the "pi flushed before snapshot" invariant
 * from S18a: if the restored session file were captured before pi finished
 * writing the turn, the rebuilt transcript would be wrong/truncated-badly and
 * this assertion would fail.
 */

let harness: E2eHarness;
const repo = mkdtempSync(path.join(tmpdir(), "proj-rollback-repo-"));

const FILE_A = path.join(repo, "alpha.txt");
const FILE_B = path.join(repo, "beta.txt");

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
    chunkDelayMs: 10,
    reply: () => "Wrote the file for you.",
    // One real pi `write` per turn (the diff.spec pattern): answer with text once
    // the tool result for THIS turn is back.
    toolCall: (lastUser, body) => {
      const lastUserIndex = body.messages.map((m) => m.role).lastIndexOf("user");
      const toolRanThisTurn = body.messages.slice(lastUserIndex + 1).some((m) => m.role === "tool");
      if (toolRanThisTurn) return null;
      if (lastUser.includes("alpha")) {
        return { name: "write", arguments: { path: FILE_A, content: "alpha body\n" } };
      }
      if (lastUser.includes("beta")) {
        return { name: "write", arguments: { path: FILE_B, content: "beta body\n" } };
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

test("roll a session back to turn 1: turn-2 file gone, turn-1 file kept, conversation truncated", async ({
  page,
}) => {
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(repo));
  await expect(page.getByTestId("session-cwd")).toHaveText(repo);
  await page.getByTestId("new-chat").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  // Open the checkpoints panel up front so we can gate each turn on its capture.
  await page.getByTestId("checkpoints-toggle").click();
  await expect(page.getByTestId("checkpoints-panel")).toBeVisible();

  const checkpointCount = async (): Promise<number> => {
    await page.getByTestId("checkpoints-refresh").click();
    return await page.getByTestId("checkpoint-row").count();
  };

  // Turn 1: pi writes alpha.txt.
  await page.getByTestId("composer-input").fill("please write the alpha file");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle", {
    timeout: 60_000,
  });
  await expect.poll(() => existsSync(FILE_A), { timeout: 30_000 }).toBe(true);
  // GATE: wait for turn 1's checkpoint (turnIndex 0) to be FULLY captured before
  // turn 2 writes beta.txt — the worktree half is captured lazily off idle, so
  // its git ref must land while only alpha.txt exists (else it would snapshot
  // beta.txt too, and rolling back to turn 1 would wrongly keep it). This is the
  // correct-usage guard on the S18a forked best-effort capture.
  await expect.poll(checkpointCount, { timeout: 30_000 }).toBe(1);

  // Turn 2: pi writes beta.txt.
  await page.getByTestId("composer-input").fill("please write the beta file");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle", {
    timeout: 60_000,
  });
  await expect.poll(() => existsSync(FILE_B), { timeout: 30_000 }).toBe(true);
  await expect.poll(checkpointCount, { timeout: 30_000 }).toBe(2);

  // Both turns are in the transcript.
  await expect(page.getByTestId("user-cell")).toHaveCount(2);

  // Roll back to turn 1 (checkpoint turnIndex 0): open the destructive-confirm
  // dialog and confirm.
  const turn1Row = page.locator('[data-testid="checkpoint-row"][data-turn="0"]');
  await turn1Row.getByTestId("checkpoint-restore").click();
  await expect(page.getByTestId("rollback-confirm")).toBeVisible();
  await page.getByTestId("rollback-confirm-button").click();

  // The dialog closes on success and pi is relaunched from the restored snapshot.
  await expect(page.getByTestId("rollback-confirm")).toHaveCount(0, { timeout: 60_000 });
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle", {
    timeout: 60_000,
  });

  // (i) turn-2's file is GONE from the worktree (git-restore + clean discarded it).
  await expect.poll(() => existsSync(FILE_B), { timeout: 30_000 }).toBe(false);
  // (ii) turn-1's file is still present.
  expect(existsSync(FILE_A)).toBe(true);

  // (iii) the CONVERSATION is truncated to turn 1 — exactly one user message,
  // and it is the alpha turn, not the beta turn. This is the flush-invariant
  // guard: a badly-captured snapshot would rebuild the wrong transcript here.
  await expect(page.getByTestId("user-cell")).toHaveCount(1, { timeout: 30_000 });
  await expect(page.getByTestId("transcript")).toContainText("alpha");
  await expect(page.getByTestId("transcript")).not.toContainText("beta");
});
