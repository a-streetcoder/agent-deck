import { existsSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startHarness, type E2eHarness } from "../helpers/env.ts";
import { expect, test, type Page } from "../helpers/fixtures.ts";

/**
 * Visual regression gate (docs/effect-migration-plan.md — standing gate for the
 * substrate migration): a SMALL set of masked, deterministic screenshots of
 * stable screens. The behavior specs can't see style breakage — a broken layout
 * or invisible text still has a structurally-correct DOM — so these fail when
 * rendering drifts. Every baseline is a maintenance cost: add screens only when
 * they guard something the existing set doesn't.
 *
 * Baselines are platform-specific (font rendering differs per OS): Playwright
 * suffixes each snapshot with the platform, and a platform WITHOUT committed
 * baselines skips rather than fails, so CI legs on other OSes aren't broken by
 * a baseline set generated here. Regenerate intentionally with:
 *   pnpm --filter @agent-deck/e2e test:visual:update
 */

const SNAPSHOT_DIR = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "visual.spec.ts-snapshots",
);
const HAS_PLATFORM_BASELINES =
  existsSync(SNAPSHOT_DIR) &&
  readdirSync(SNAPSHOT_DIR).some((f) => f.includes(`-${process.platform}`));

// `--update-snapshots` surfaces via config.updateSnapshots ("all", or "changed"
// for the bare flag) — the CLI flag never reaches worker argv, so testInfo is
// the only reliable signal. Without it the mode is "missing" (or "none" on CI),
// and a platform with no committed baselines must skip, not fail.
//
// CI runners also skip (unless AGENT_DECK_VISUAL=1 opts in): baselines are
// generated on a dev machine, and runner font rendering differs enough to
// produce false diffs — CI's job is the behavioral e2e matrix; the visual gate
// is a local pre-commit gate.
// eslint-disable-next-line no-empty-pattern -- Playwright requires a destructuring pattern here
test.beforeEach(({}, testInfo) => {
  const updating =
    testInfo.config.updateSnapshots === "all" || testInfo.config.updateSnapshots === "changed";
  test.skip(!!process.env.CI && process.env.AGENT_DECK_VISUAL !== "1", "visual gate is local-only");
  test.skip(
    !HAS_PLATFORM_BASELINES && !updating,
    `no visual baselines for ${process.platform} — generate with test:visual:update`,
  );
});

// A fixed viewport: baseline diffs must mean rendering changed, not the window.
test.use({ viewport: { width: 1280, height: 800 } });

const REPLY = "The visual baseline reply: stable, short, and fully deterministic.";

let harness: E2eHarness;

test.beforeAll(async () => {
  // Deterministic terminal chrome for the drawer baseline: pin the shell (the
  // server-side AGENT_DECK_TERMINAL_SHELL test seam) and give it a fixed
  // prompt, so no machine cwd path ever renders inside the terminal.
  process.env.AGENT_DECK_TERMINAL_SHELL =
    process.platform === "win32"
      ? (process.env.ComSpec ?? "C:\\Windows\\System32\\cmd.exe")
      : "/bin/sh";
  process.env.PROMPT = "agent-deck$G";
  process.env.PS1 = "agent-deck> ";
  harness = await startHarness({ reply: () => REPLY, chunkDelayMs: 0 });
});

test.afterAll(async () => {
  await harness.close();
});

/**
 * Chrome that legitimately varies run-to-run — temp cwd paths, relative times,
 * token/cost stats, per-run durations. Masked, not asserted; a locator that
 * matches nothing masks nothing.
 */
const dynamicChrome = (page: Page) => [
  page.getByTestId("session-cwd"),
  page.getByTestId("startup-cwd"),
  // The whole collapsed session list (titles, agent names, relative times) —
  // masking its rows individually would also stamp boxes over the HIDDEN
  // expanded-panel copies of those rows, which overlay the nav.
  page.getByTestId("chat-list"),
  page.getByTestId("context-usage"),
  page.getByTestId("session-tokens"),
  page.getByTestId("session-cost"),
  page.getByTestId("run-meta"),
];

const SCREENSHOT_OPTS = { animations: "disabled" as const, maxDiffPixelRatio: 0.01 };

// Screen order matters: the exchange test creates a session, which would make
// the sidebar's sessions panel nondeterministic for any LATER full-page shot —
// so the full-page screens run first and the session-creating one runs last.

test("visual: app shell (sidebar + empty chat)", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");
  await expect(page.getByTestId("sidebar")).toBeVisible();
  await expect(page).toHaveScreenshot("app-shell.png", {
    ...SCREENSHOT_OPTS,
    mask: dynamicChrome(page),
  });
});

test("visual: skills screen", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");
  await page.getByTestId("nav-skills").click();
  await expect(page.getByTestId("app-view-title")).toContainText("Skills");
  await expect(page).toHaveScreenshot("skills-screen.png", {
    ...SCREENSHOT_OPTS,
    mask: dynamicChrome(page),
  });
});

test("visual: session view with the terminal drawer open", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  await page.getByTestId("terminal-toggle").click();
  const drawer = page.getByTestId("terminal-drawer");
  await expect(drawer).toBeVisible();
  const rows = page.locator(".xterm-rows");
  await expect(rows).toContainText("agent-deck>", { timeout: 15_000 });

  // Wipe the shell banner (cmd prints an OS version line), then run one echo,
  // leaving a fully deterministic screen: prompt+command, output, prompt.
  await drawer.locator(".xterm").click();
  await page.keyboard.type(process.platform === "win32" ? "cls" : "clear");
  await page.keyboard.press("Enter");
  await expect
    .poll(async () => ((await rows.innerText()).match(/agent-deck>/g) ?? []).length, {
      timeout: 15_000,
    })
    .toBe(1);
  await page.keyboard.type("echo visual-baseline-echo");
  await page.keyboard.press("Enter");
  // Settled = the output line arrived AND the next prompt is back: the sentinel
  // renders twice (typed + output) and a second prompt follows the first.
  await expect
    .poll(
      async () => {
        const text = await rows.innerText();
        return (
          (text.match(/visual-baseline-echo/g) ?? []).length >= 2 &&
          (text.match(/agent-deck>/g) ?? []).length >= 2
        );
      },
      { timeout: 15_000 },
    )
    .toBe(true);

  // Clip to the chat layer (the drawer's mount) like the transcript baseline;
  // the sidebar's nondeterministic session list stays out of frame.
  await expect(page.getByTestId("chat-layer")).toHaveScreenshot("terminal-drawer.png", {
    ...SCREENSHOT_OPTS,
    mask: dynamicChrome(page),
  });
});

test("visual: transcript with a completed exchange", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle");

  await page.getByTestId("composer-input").fill("visual baseline prompt");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("status-indicator")).toHaveAttribute("data-status", "idle", {
    timeout: 60_000,
  });
  await expect(page.getByTestId("assistant-text")).toContainText("deterministic");
  // The context/token chips arrive async after idle (get_session_stats); wait so
  // the composer is in its settled post-turn layout, then mask their values.
  await expect(page.getByTestId("session-tokens")).toBeVisible({ timeout: 15_000 });

  // Clip to the chat layer: the sidebar's session list (title generation, times)
  // is nondeterministic and is covered structurally by the behavior specs.
  await expect(page.getByTestId("chat-layer")).toHaveScreenshot("transcript-exchange.png", {
    ...SCREENSHOT_OPTS,
    mask: dynamicChrome(page),
  });
});
