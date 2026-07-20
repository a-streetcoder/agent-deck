import { expect, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Slice 8b gate: the per-session terminal drawer against the REAL stack —
 * server-spawned PTY (node-pty), Effect-RPC terminal ops over `/rpc`, xterm in
 * the browser. Covers the drawer contract end-to-end: open lazily spawns the
 * shell, typed input round-trips (a command produces output), closing the
 * drawer keeps the terminal alive, and reopening replays the scrollback.
 *
 * Determinism: the harness pins the shell via AGENT_DECK_TERMINAL_SHELL (the
 * server-side test seam) — cmd.exe with a fixed PROMPT on Windows, /bin/sh
 * with PS1 elsewhere — so prompts don't leak machine-specific paths and the
 * command syntax below is known. The echoed value is assembled from a shell
 * variable so the asserted string ("hello-terminal") can only appear as real
 * PTY OUTPUT — the typed command never contains it whole.
 */

const isWindows = process.platform === "win32";
const SET_PART = isWindows ? "set part=hello-" : "part=hello-";
const ECHO_JOINED = isWindows ? "echo %part%terminal" : "echo ${part}terminal";

let harness: E2eHarness;

test.beforeAll(async () => {
  process.env.AGENT_DECK_TERMINAL_SHELL = isWindows
    ? (process.env.ComSpec ?? "C:\\Windows\\System32\\cmd.exe")
    : "/bin/sh";
  // A fixed prompt (cmd reads PROMPT, sh reads PS1) — no cwd path noise.
  process.env.PROMPT = "agent-deck$G";
  process.env.PS1 = "agent-deck> ";
  harness = await startHarness({ reply: () => "ok" });
});

test.afterAll(async () => {
  await harness.close();
});

test("terminal drawer: lazy open, echo round-trip, scrollback replay on reopen", async ({
  page,
}) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  // Open the drawer; the server spawns the shell lazily on first open.
  await page.getByTestId("terminal-toggle").click();
  const drawer = page.getByTestId("terminal-drawer");
  await expect(drawer).toBeVisible();

  // The pinned shell prints its fixed prompt once it is live.
  const rows = page.locator(".xterm-rows");
  await expect(rows).toContainText("agent-deck>", { timeout: 15_000 });

  // Type a command whose OUTPUT (not its typed text) contains the sentinel.
  await drawer.locator(".xterm").click();
  await page.keyboard.type(SET_PART);
  await page.keyboard.press("Enter");
  await page.keyboard.type(ECHO_JOINED);
  await page.keyboard.press("Enter");
  await expect(rows).toContainText("hello-terminal", { timeout: 15_000 });

  // The PTY spawned in the SESSION's cwd (the server resolves it from
  // meta.cwd — the same field that is worktree-aware for worktree sessions):
  // printing the shell's cwd must match the header's session-cwd chip.
  const sessionCwd = ((await page.getByTestId("session-cwd").textContent()) ?? "").trim();
  expect(sessionCwd.length).toBeGreaterThan(0);
  await page.keyboard.type(isWindows ? "cd" : "pwd");
  await page.keyboard.press("Enter");
  // Separator-agnostic match (the store may hold `/` where the shell prints
  // `\`), case-insensitive for Windows drive letters.
  const cwdPattern = sessionCwd
    .split(/[\\/]+/)
    .map((segment) => segment.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
    .join("[\\\\/]+");
  await expect(rows).toContainText(new RegExp(cwdPattern, "i"), { timeout: 15_000 });

  // Close the drawer: the renderer goes away, the PTY stays alive server-side.
  await page.getByTestId("terminal-hide").click();
  await expect(drawer).toHaveCount(0);

  // Reopen: the drawer reattaches by terminal id and the server replays the
  // scrollback — the earlier output is visible again without re-running it.
  await page.getByTestId("terminal-toggle").click();
  await expect(page.getByTestId("terminal-drawer")).toBeVisible();
  await expect(page.locator(".xterm-rows")).toContainText("hello-terminal", { timeout: 15_000 });
});

test("keyboard shortcut toggles the drawer", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  await page.keyboard.press("Control+`");
  await expect(page.getByTestId("terminal-drawer")).toBeVisible();
  await expect(page.locator(".xterm-rows")).toContainText("agent-deck>", { timeout: 15_000 });

  // The shortcut also closes it from INSIDE the terminal (xterm declines the
  // combo so it bubbles to the app shortcut handler).
  await page.locator(".xterm").click();
  await page.keyboard.press("Control+`");
  await expect(page.getByTestId("terminal-drawer")).toHaveCount(0);
});
