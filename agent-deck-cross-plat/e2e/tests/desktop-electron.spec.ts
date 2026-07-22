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

  // A fresh data dir has no projects, so the first-run onboarding modal would
  // cover the UI and intercept clicks. Pre-dismiss it (this suite tests the shell,
  // not onboarding — that has its own web e2e).
  const window = await app.firstWindow();
  await window.addInitScript(() => {
    try {
      localStorage.setItem("agentdeck-onboarding-dismissed", "1");
    } catch {
      // Storage disabled — harmless.
    }
  });
  await window.reload();
});

test.afterAll(async () => {
  // Graceful quit runs the main process's before-quit → server-tree teardown
  // (now synchronous on Windows, so the server tree is reaped before Electron
  // exits). Cap it; only if the graceful quit HANGS do we force-kill the tree.
  const closedGracefully = await Promise.race([
    app
      ?.close()
      .then(() => true)
      .catch(() => true),
    new Promise((resolve) => setTimeout(() => resolve(false), 10_000)),
  ]);
  // Only reap when the graceful close timed out (Electron still alive/hung): a
  // tree-kill by the Electron PID after it already exited could hit a reused PID.
  if (!closedGracefully && electronPid) {
    try {
      if (process.platform === "win32") {
        // SIGKILL to the Electron PID does NOT cascade to its spawned child tree
        // (the server via pnpm -> node) on Windows; taskkill /T reaps the whole
        // tree so no orphan keeps the Playwright worker past its teardown deadline.
        execSync(`taskkill /F /T /PID ${electronPid}`, { stdio: "ignore" });
      } else {
        process.kill(electronPid, "SIGKILL");
      }
    } catch {
      // Already gone.
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

  // Windows/Linux use the CrunchyMurmur-style integrated title bar while the
  // native window controls remain owned by Electron's titleBarOverlay.
  const titlebar = window.getByTestId("desktop-titlebar");
  await expect(titlebar).toBeVisible();
  await expect(window.getByTestId("sidebar-brand")).toHaveText("AGENTDECK");
  const sidebarToggle = window.getByTestId("desktop-sidebar-toggle");
  await expect(sidebarToggle).toHaveAttribute("aria-label", "Hide sidebar");
  await expect(window.getByTestId("desktop-menu-file")).toHaveText("File");
  await expect(window.getByTestId("desktop-menu-edit")).toHaveText("Edit");
  await expect(window.getByTestId("desktop-menu-view")).toHaveText("View");
  await expect(window.getByTestId("desktop-menu-help")).toHaveText("Help");

  const chrome = await window.evaluate(() => {
    const browser = globalThis as unknown as {
      document: { querySelector(selector: string): unknown };
      getComputedStyle(
        element: unknown,
        pseudo?: string,
      ): {
        height: string;
        borderTopLeftRadius: string;
        borderTopRightRadius: string;
        backgroundColor: string;
        width: string;
        marginLeft: string;
      };
      agentDeck?: { openAppMenu?: unknown };
    };
    const titlebar = browser.document.querySelector('[data-testid="desktop-titlebar"]');
    const workspaceRow = browser.document.querySelector('[data-testid="workspace-row"]');
    const workspace = browser.document.querySelector('[data-testid="workspace-shell"]');
    const sidebar = browser.document.querySelector('[data-testid="sidebar"]');
    const transcript = browser.document.querySelector('[data-testid="transcript"]');
    return {
      titlebarHeight: titlebar ? browser.getComputedStyle(titlebar).height : "",
      workspaceTopLeftRadius: workspace
        ? browser.getComputedStyle(workspace).borderTopLeftRadius
        : "",
      workspaceTopRightRadius: workspace
        ? browser.getComputedStyle(workspace).borderTopRightRadius
        : "",
      workspaceInset: workspace ? browser.getComputedStyle(workspace).marginLeft : "",
      cornerBackgroundMatchesSidebar:
        workspaceRow && sidebar
          ? browser.getComputedStyle(workspaceRow).backgroundColor ===
            browser.getComputedStyle(sidebar).backgroundColor
          : false,
      scrollbarWidth: transcript
        ? browser.getComputedStyle(transcript, "::-webkit-scrollbar").width
        : "",
      menuBridge: typeof browser.agentDeck?.openAppMenu === "function",
    };
  });
  expect(chrome).toEqual({
    titlebarHeight: "40px",
    workspaceTopLeftRadius: "14px",
    workspaceTopRightRadius: "0px",
    workspaceInset: "0px",
    cornerBackgroundMatchesSidebar: true,
    scrollbarWidth: "8px",
    menuBridge: true,
  });

  // Native menus open at the clicked item's left edge and the titlebar's
  // bottom edge, matching Codex instead of Electron's cursor-position default.
  await app.evaluate(({ Menu }) => {
    const file = Menu.getApplicationMenu()?.items.find((item) => item.label === "File");
    if (!file?.submenu) throw new Error("File menu unavailable");
    const state = globalThis as typeof globalThis & {
      agentDeckPopupAnchor?: { x: number; y: number };
    };
    file.submenu.popup = (options) => {
      state.agentDeckPopupAnchor = { x: options?.x ?? -1, y: options?.y ?? -1 };
    };
  });
  const fileButton = window.getByTestId("desktop-menu-file");
  const fileBounds = await fileButton.boundingBox();
  const titlebarBounds = await titlebar.boundingBox();
  if (!fileBounds || !titlebarBounds) throw new Error("Titlebar bounds unavailable");
  await fileButton.click();
  await expect
    .poll(() =>
      app.evaluate(() => {
        const state = globalThis as typeof globalThis & {
          agentDeckPopupAnchor?: { x: number; y: number };
        };
        return state.agentDeckPopupAnchor;
      }),
    )
    .toEqual({
      x: Math.round(fileBounds.x),
      y: Math.round(titlebarBounds.y + titlebarBounds.height),
    });

  // The titlebar icon hides and restores the native-style sidebar. With no
  // sidebar junction, the workspace returns to a square top-left corner.
  await sidebarToggle.click();
  await expect(window.getByTestId("sidebar")).toHaveCount(0);
  await expect(sidebarToggle).toHaveAttribute("aria-label", "Show sidebar");
  await expect(window.getByTestId("workspace-shell")).toHaveCSS("border-top-left-radius", "0px");
  await sidebarToggle.click();
  await expect(window.getByTestId("sidebar")).toBeVisible();

  // The same-origin server the main process spawned answers health checks.
  const health = await window.evaluate(async () => {
    const res = await fetch("/health");
    return res.ok;
  });
  expect(health).toBe(true);
});

test("adding a project via the native folder picker registers it", async () => {
  const window = await app.firstWindow();
  // Project selection lives in the toolbar picker popover (native), so open it.
  await window.getByTestId("project-picker").click({ timeout: 30_000 });
  await expect(window.getByTestId("add-project")).toBeVisible({ timeout: 30_000 });

  // Stub the OS folder chooser to return our throwaway project directory, so
  // the real preload → ipcMain → dialog → addProject chain runs headlessly.
  await app.evaluate(({ dialog }, dir) => {
    dialog.showOpenDialog = () => Promise.resolve({ canceled: false, filePaths: [dir] });
  }, projectDir);

  await window.getByTestId("add-project").click();

  // The picked folder shows up as a registered project; reopen the picker to see it.
  await window.getByTestId("project-picker").click();
  await expect(window.getByTestId(`project-${projectName}`)).toBeVisible({ timeout: 15_000 });
});

test("the native File menu exposes New Chat and it creates a session", async () => {
  const window = await app.firstWindow();

  const fileItems = await app.evaluate(({ Menu }) => {
    const file = Menu.getApplicationMenu()?.items.find((i) => i.label === "File");
    return file?.submenu?.items.map((i) => i.label) ?? [];
  });
  expect(fileItems).toContain("New Chat");
  const helpItems = await app.evaluate(({ Menu }) => {
    const help = Menu.getApplicationMenu()?.items.find((i) => i.label === "Help");
    return help?.submenu?.items.map((i) => i.label) ?? [];
  });
  expect(helpItems).toContain("Agent Deck on GitHub");
  expect(helpItems).toContain("About Agent Deck");
  expect(fileItems).toContain("Add Project…");
  // Non-rebindable recovery path into the keybindings editor (the palette's
  // open-chord is itself user-rebindable, so the menu is the reset fallback).
  expect(fileItems).toContain("Edit Keybindings…");

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

test("File → Edit Keybindings… opens the editor (palette-independent recovery)", async () => {
  const window = await app.firstWindow();
  const editor = window.getByTestId("keybindings-editor");
  await expect(editor).toHaveCount(0);

  // Fire the native menu item → IPC → renderer opens the editor, with no
  // dependency on the (rebindable) command-palette open-chord.
  await app.evaluate(({ Menu }) => {
    const file = Menu.getApplicationMenu()?.items.find((i) => i.label === "File");
    file?.submenu?.items.find((i) => i.label === "Edit Keybindings…")?.click();
  });
  await expect(editor).toBeVisible();
  await window.getByTestId("keybindings-editor-close").click();
  await expect(editor).toHaveCount(0);
});

test("the browser workspace tab mounts a real <webview> guest and navigates", async () => {
  const window = await app.firstWindow();
  await window.waitForLoadState("domcontentloaded");

  // (a) The host BrowserWindow enables the <webview> tag (else the guest can't
  // instantiate). getLastWebPreferences reflects the constructor webPreferences.
  const webviewTagEnabled = await app.evaluate(({ BrowserWindow }) => {
    const win = BrowserWindow.getAllWindows()[0];
    return win?.webContents.getLastWebPreferences()?.webviewTag ?? false;
  });
  expect(webviewTagEnabled).toBe(true);

  // A chat session makes the desktop-only header browser toggle available.
  await app.evaluate(({ Menu }) => {
    const file = Menu.getApplicationMenu()?.items.find((i) => i.label === "File");
    file?.submenu?.items.find((i) => i.label === "New Chat")?.click();
  });
  const browserToggle = window.getByTestId("browser-toggle");
  await expect(browserToggle).toBeVisible({ timeout: 15_000 });

  // (b) Toggling opens the browser tab: the workspace body, a real <webview>
  // guest, and the toolbar (address input + back/forward) are all present.
  await browserToggle.click();
  await expect(window.getByTestId("workspace-body-browser")).toBeVisible();
  await expect(window.getByTestId("browser-url-input")).toBeVisible();
  await expect(window.getByTestId("browser-back")).toBeVisible();
  await expect(window.getByTestId("browser-forward")).toBeVisible();
  // One live guest for the single starting page.
  await expect(window.locator("webview")).toHaveCount(1);

  // (c) Drive a navigation via the address bar to a data: URL (no network in CI)
  // and assert the nav state (title from page-title-updated, url from
  // did-navigate) flows into the panel.
  const dataUrl = "data:text/html,<title>L2%20Browser</title><h1>hi</h1>";
  const input = window.getByTestId("browser-url-input");
  await input.click();
  await input.fill(dataUrl);
  await input.press("Enter");
  await expect(window.getByTestId("browser-page-title")).toHaveText("L2 Browser", {
    timeout: 15_000,
  });
  await expect(input).toHaveValue(/^data:text\/html/);

  // (d) Opening a new internal page-tab yields a SECOND <webview> — the first
  // guest stays mounted (keep-alive), so both live at once.
  await window.getByTestId("browser-new-page").click();
  await expect(window.locator("webview")).toHaveCount(2);

  // Leave the workspace clean for the following tests: close the browser tab.
  await browserToggle.click();
  await expect(window.getByTestId("workspace-body-browser")).toHaveCount(0);
});

test("attention events notify + badge while unfocused, and focus clears the badge", async () => {
  const window = await app.firstWindow();
  await window.waitForLoadState("domcontentloaded");

  // Install main-process spies (Slice 22a): record setBadgeCount + notification
  // shows, force isFocused()=false so the focus gate lets events through, and
  // force Notification.isSupported()=true. Stubbing Notification.prototype.show
  // works because main.js's `new Notification(...)` shares this exact prototype.
  await app.evaluate(({ app: electronApp, BrowserWindow, Notification }) => {
    const win = BrowserWindow.getAllWindows()[0];
    if (!win) throw new Error("no window");
    const g = globalThis as typeof globalThis & {
      agentDeckAttention?: {
        badge: number[];
        notifications: Array<{ title: string; body: string }>;
      };
    };
    g.agentDeckAttention = { badge: [], notifications: [] };
    electronApp.setBadgeCount = (n: number) => {
      g.agentDeckAttention!.badge.push(n);
      return true;
    };
    win.isFocused = () => false;
    Notification.isSupported = () => true;
    (Notification.prototype as unknown as { show: () => void }).show = function (this: {
      title?: string;
      body?: string;
    }) {
      g.agentDeckAttention!.notifications.push({ title: this.title ?? "", body: this.body ?? "" });
    };
    // Re-baseline the counter + recording so a stray startup focus can't skew it.
    win.emit("focus");
    g.agentDeckAttention = { badge: [], notifications: [] };
  });

  const readAttention = () =>
    app.evaluate(() => {
      const g = globalThis as typeof globalThis & {
        agentDeckAttention?: {
          badge: number[];
          notifications: Array<{ title: string; body: string }>;
        };
      };
      return g.agentDeckAttention ?? { badge: [], notifications: [] };
    });

  // Turn complete while unfocused → one notification + badge 1.
  await window.evaluate(() => {
    (
      window as unknown as { agentDeck?: { signalAttention?(p: unknown): void } }
    ).agentDeck?.signalAttention?.({
      kind: "turn-complete",
      title: "My session",
      body: "Turn complete",
    });
  });
  await expect.poll(async () => (await readAttention()).badge.at(-1)).toBe(1);
  {
    const state = await readAttention();
    expect(state.notifications).toContainEqual({ title: "My session", body: "Turn complete" });
  }

  // Approval needed while unfocused → a second notification + badge 2.
  await window.evaluate(() => {
    (
      window as unknown as { agentDeck?: { signalAttention?(p: unknown): void } }
    ).agentDeck?.signalAttention?.({
      kind: "approval-needed",
      title: "My session",
      body: "Run rm -rf build?",
    });
  });
  await expect.poll(async () => (await readAttention()).badge.at(-1)).toBe(2);
  {
    const state = await readAttention();
    expect(state.notifications).toContainEqual({ title: "My session", body: "Run rm -rf build?" });
  }

  // Focusing the window clears the badge (attention "seen").
  await app.evaluate(({ BrowserWindow }) => {
    BrowserWindow.getAllWindows()[0]?.emit("focus");
  });
  await expect.poll(async () => (await readAttention()).badge.at(-1)).toBe(0);

  // A focused window suppresses both notification and badge bump.
  await app.evaluate(({ BrowserWindow }) => {
    const win = BrowserWindow.getAllWindows()[0]!;
    win.isFocused = () => true;
    const g = globalThis as typeof globalThis & {
      agentDeckAttention?: { badge: number[]; notifications: Array<unknown> };
    };
    g.agentDeckAttention = { badge: [], notifications: [] };
  });
  await window.evaluate(() => {
    (
      window as unknown as { agentDeck?: { signalAttention?(p: unknown): void } }
    ).agentDeck?.signalAttention?.({
      kind: "turn-complete",
      title: "My session",
      body: "Turn complete",
    });
  });
  // Give the fire-and-forget IPC a beat, then assert nothing was recorded.
  await window.waitForTimeout(200);
  {
    const state = await readAttention();
    expect(state.badge).toEqual([]);
    expect(state.notifications).toEqual([]);
  }
});

test("the app presents itself as Agent Deck", async () => {
  const name = await app.evaluate(({ app: electronApp }) => electronApp.getName());
  expect(name).toBe("Agent Deck");
});
