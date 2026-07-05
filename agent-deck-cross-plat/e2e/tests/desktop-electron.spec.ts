import { createRequire } from "node:module";
import { execSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { _electron as electron, expect, test, type ElectronApplication } from "@playwright/test";

/**
 * Phase-1 gate for the Electron shell: launching the real app boots the same
 * Fastify+pi server the CLI runs (on a free port, owned by the main process),
 * loads the built web UI same-origin, and exposes the native-bridge preload.
 *
 * Streaming/chat is already gated by the browser e2e against the identical
 * server; here we only prove the desktop shell wires renderer → server → OS
 * bridge together and tears the server down on exit.
 */

const WORKSPACE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const DESKTOP_DIR = path.join(WORKSPACE_ROOT, "apps", "desktop");
const WEB_DIST = path.join(WORKSPACE_ROOT, "apps", "web", "dist");

// Resolve Electron's binary from the desktop package (it's not an e2e dep).
const requireFromDesktop = createRequire(path.join(DESKTOP_DIR, "package.json"));
const electronPath = requireFromDesktop("electron") as string;

let app: ElectronApplication;
let electronPid: number | undefined;

test.beforeAll(async () => {
  if (!existsSync(path.join(WEB_DIST, "index.html"))) {
    execSync("pnpm --filter @agent-deck/web build", { cwd: WORKSPACE_ROOT, stdio: "inherit" });
  }
  // The main process spawns the server via pnpm, which needs the real HOME
  // (a throwaway HOME sends corepack into a reinstall that aborts with no TTY).
  // This boot smoke sends no prompt, so it neither launches pi nor mutates
  // anything under ~/.pi — read-only against the real home is safe.
  app = await electron.launch({
    executablePath: electronPath,
    args: [DESKTOP_DIR],
    env: { ...process.env, PI_SKIP_VERSION_CHECK: "1" },
  });
  electronPid = app.process().pid ?? undefined;
});

test.afterAll(async () => {
  // Graceful quit runs the main process's before-quit → server-tree teardown.
  // Cap it so a slow quit can't fail the hook, then hard-stop as a safety net.
  await Promise.race([
    app?.close().catch(() => {}),
    new Promise((resolve) => setTimeout(resolve, 10_000)),
  ]);
  if (electronPid) {
    try {
      process.kill(electronPid, "SIGKILL");
    } catch {
      // Already gone — the graceful close won.
    }
  }
});

test("the desktop shell boots the server and mounts the UI", async () => {
  const window = await app.firstWindow();
  await window.waitForLoadState("domcontentloaded");

  // The sidebar renders → the React bundle served by the in-process server ran.
  await expect(window.getByTestId("nav-projects")).toBeVisible({ timeout: 30_000 });

  // The preload bridge is present → the native folder picker is reachable.
  const bridge = await window.evaluate(
    () =>
      (window as unknown as { agentDeck?: { isElectron?: boolean } }).agentDeck?.isElectron ?? false,
  );
  expect(bridge).toBe(true);

  // The same-origin server the main process spawned answers health checks.
  const health = await window.evaluate(async () => {
    const res = await fetch("/health");
    return res.ok;
  });
  expect(health).toBe(true);
});
