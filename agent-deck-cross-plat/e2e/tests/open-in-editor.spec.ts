import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, selectProject, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Slice 11 gate: open-in-editor from the diff surfaces against a STUB editor.
 * `AGENT_DECK_OPEN_BIN` (the AGENT_DECK_GH_BIN precedent) points the server's
 * editor launcher at a recorder script, so the test asserts the EXACT launch
 * argv — the resolved absolute file target and the per-editor line syntax —
 * without ever spawning a real editor window. Windows runs the stub as a
 * `.cmd` (exercising the batch-shim shell hop for real); posix as a sh script.
 */

let harness: E2eHarness;
const repo = mkdtempSync(path.join(tmpdir(), "proj-openin-repo-"));
const stubDir = mkdtempSync(path.join(tmpdir(), "open-stub-"));
const argvFile = path.join(stubDir, "argv.txt");
const isWindows = process.platform === "win32";
const stub = path.join(stubDir, isWindows ? "open-stub.cmd" : "open-stub");

const CHANGED_FILE = path.join(repo, "src", "feature.txt");

function readArgv(): string {
  try {
    return readFileSync(argvFile, "utf8");
  } catch {
    return "";
  }
}

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
  // One untracked change present BEFORE the session starts: the subscribe-time
  // diff_files fetch alone populates the badge/tree (no pi turn needed).
  mkdirSync(path.join(repo, "src"));
  writeFileSync(CHANGED_FILE, "alpha line\nbeta line\n");

  // The stub editor: append the received argv to a file the test polls.
  if (isWindows) {
    writeFileSync(stub, `@echo off\r\necho %* >> "${argvFile}"\r\n`);
  } else {
    writeFileSync(stub, `#!/bin/sh\necho "$@" >> "${argvFile}"\n`);
    chmodSync(stub, 0o755);
  }
  process.env.AGENT_DECK_OPEN_BIN = stub;

  harness = await startHarness({ chunkDelayMs: 20 });
  const response = await fetch(`${harness.baseUrl}/projects`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ path: repo }),
  });
  if (!response.ok) throw new Error(await response.text());
});

test.afterAll(async () => {
  delete process.env.AGENT_DECK_OPEN_BIN;
  await harness.close();
});

test("tree hover action and header picker launch the stub with the exact target", async ({
  page,
}) => {
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(repo));
  await expect(page.getByTestId("session-cwd")).toHaveText(repo);
  await page.getByTestId("new-chat").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  // Dirty-at-start repo: the subscribe-time fetch shows the one changed file.
  await expect(page.getByTestId("diff-badge")).toHaveText("1", { timeout: 30_000 });
  await page.getByTestId("diff-toggle").click();
  await expect(page.getByTestId("diff-panel")).toBeVisible();
  const row = page.locator('[data-testid="diff-tree-file"][data-path="src/feature.txt"]');
  await expect(row).toBeVisible();

  // Tree row: the open action is hover-revealed (hidden at rest, so the
  // resting layout — and the Slice-10 visual baseline — is unchanged).
  const treeOpen = row.getByTestId("diff-tree-open");
  await expect(treeOpen).toBeHidden();
  await row.hover();
  await expect(treeOpen).toBeVisible();
  await treeOpen.click();
  // The stub received the RESOLVED absolute path (no line: nothing loaded a
  // patch yet, and the tree action opens the file plain).
  await expect.poll(readArgv, { timeout: 15_000 }).toContain(CHANGED_FILE);
  expect(readArgv()).not.toContain("--goto");

  // File header: open the file's diff, pick VS Code from the chevron menu —
  // the goto family launches `--goto <abs>:<first-changed-line>`.
  await row.click();
  await expect(page.getByTestId("diff-file-view")).toBeVisible();
  await expect(page.locator('[data-testid="diff-line"][data-kind="add"]').first()).toBeVisible({
    timeout: 15_000,
  });
  await page.getByTestId("diff-file-path").hover();
  await page.getByTestId("open-in-menu-trigger").click();
  await expect(page.getByTestId("open-in-menu")).toBeVisible();
  await page.getByTestId("open-in-option-vscode").click();
  await expect(page.getByTestId("open-in-menu")).toBeHidden();
  await expect.poll(readArgv, { timeout: 15_000 }).toContain("--goto");
  expect(readArgv()).toContain(`${CHANGED_FILE}:1`);

  // The choice is REMEMBERED (AppSettings): the server soon reports vscode
  // (the picker persists via a fire-and-forget PATCH — poll for it).
  await expect
    .poll(
      async () => {
        const settings = await fetch(`${harness.baseUrl}/settings`);
        const body = (await settings.json()) as {
          settings?: { preferredEditor?: string | null };
        };
        return body.settings?.preferredEditor ?? null;
      },
      { timeout: 15_000 },
    )
    .toBe("vscode");
});
