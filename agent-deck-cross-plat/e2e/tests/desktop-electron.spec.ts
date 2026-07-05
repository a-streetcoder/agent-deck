import { createRequire } from "node:module";
import { execSync } from "node:child_process";
import { existsSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
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
// A throwaway directory to "pick" as a project, and an isolated persistence dir.
const projectDir = mkdtempSync(path.join(tmpdir(), "electron-e2e-project-"));
const projectName = path.basename(projectDir);

test.beforeAll(async () => {
  if (!existsSync(path.join(WEB_DIST, "index.html"))) {
    execSync("pnpm --filter @agent-deck/web build", { cwd: WORKSPACE_ROOT, stdio: "inherit" });
  }
  // The main process spawns the server via pnpm, which needs the real HOME
  // (a throwaway HOME sends corepack into a reinstall that aborts with no TTY).
  // This spec sends no prompt, so it never launches pi nor mutates ~/.pi; the
  // isolated AGENT_DECK_DATA_DIR keeps the added project out of real state.
  const dataDir = mkdtempSync(path.join(tmpdir(), "electron-e2e-data-"));
  // CI runs as root in a container where Chromium's setuid sandbox can't start,
  // so Electron needs --no-sandbox there (harmless locally, gated on CI).
  const launchArgs = process.env.CI ? [DESKTOP_DIR, "--no-sandbox"] : [DESKTOP_DIR];
  app = await electron.launch({
    executablePath: electronPath,
    args: launchArgs,
    env: { ...process.env, PI_SKIP_VERSION_CHECK: "1", AGENT_DECK_DATA_DIR: dataDir },
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
      (window as unknown as { agentDeck?: { isElectron?: boolean } }).agentDeck?.isElectron ??
      false,
  );
  expect(bridge).toBe(true);

  // The same-origin server the main process spawned answers health checks.
  const health = await window.evaluate(async () => {
    const res = await fetch("/health");
    return res.ok;
  });
  expect(health).toBe(true);
});

test("adding a project via the native folder picker registers it", async () => {
  const window = await app.firstWindow();
  await expect(window.getByTestId("add-project")).toBeVisible({ timeout: 30_000 });

  // Stub the OS folder chooser to return our throwaway project directory, so
  // the real preload → ipcMain → dialog → addProject chain runs headlessly.
  await app.evaluate(({ dialog }, dir) => {
    dialog.showOpenDialog = () => Promise.resolve({ canceled: false, filePaths: [dir] });
  }, projectDir);

  await window.getByTestId("add-project").click();

  // The picked folder shows up as a registered project in the sidebar.
  await expect(window.getByTestId(`project-${projectName}`)).toBeVisible({ timeout: 15_000 });
});

test("the native File menu exposes New Chat and it creates a session", async () => {
  const window = await app.firstWindow();

  const fileItems = await app.evaluate(({ Menu }) => {
    const file = Menu.getApplicationMenu()?.items.find((i) => i.label === "File");
    return file?.submenu?.items.map((i) => i.label) ?? [];
  });
  expect(fileItems).toContain("New Chat");
  expect(fileItems).toContain("Add Project…");

  const sessionCount = () =>
    window.evaluate(async () => {
      const res = await fetch("/sessions");
      const { sessions } = (await res.json()) as { sessions: unknown[] };
      return sessions.length;
    });
  const before = await sessionCount();

  // Trigger the menu item → IPC → renderer newChat() → a new session.
  await app.evaluate(({ Menu }) => {
    const file = Menu.getApplicationMenu()?.items.find((i) => i.label === "File");
    file?.submenu?.items.find((i) => i.label === "New Chat")?.click();
  });
  await expect.poll(sessionCount, { timeout: 10_000 }).toBe(before + 1);
});

test("the app presents itself as Agent Deck", async () => {
  const name = await app.evaluate(({ app: electronApp }) => electronApp.getName());
  expect(name).toBe("Agent Deck");
});
