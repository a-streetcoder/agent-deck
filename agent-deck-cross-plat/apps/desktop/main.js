// Electron main process for agent-deck.
//
// Dev-runnable shell (t3code shape): the main process owns the server's
// lifecycle — it spawns the same Fastify+pi server the CLI runs (via `pnpm
// dev`) on a free port, waits for /health, then loads the server-served web UI
// same-origin so all the relative `/sessions`, `/ws`, … paths just work. When
// the app quits, the server dies with it — no more stale-server 404s.
//
// This is the terminal-launched dev build. Packaged installers (bundled server,
// GUI-safe PATH, code-signing) are a later phase.

import { spawn, spawnSync } from "node:child_process";
import http from "node:http";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { app, BrowserWindow, dialog, ipcMain, Menu, shell } from "electron";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
// apps/desktop -> repo root (agent-deck-cross-plat).
const repoRoot = path.resolve(__dirname, "..", "..");

// Present as "Agent Deck" everywhere the OS shows the app name (menu bar,
// About panel) instead of the package/Electron default.
app.setName("Agent Deck");

/** Background dark so there's no white flash before the UI paints. */
const WINDOW_BG = "#0f1115";
const TITLEBAR_BG = "#28282b";
const TITLEBAR_SYMBOL = "#f5f5f7";

let serverProcess = null;
let serverPort = null;
let mainWindow = null;

/** Resolve pnpm's executable name per platform (dev PATH is inherited). */
function pnpmCommand() {
  return process.platform === "win32" ? "pnpm.cmd" : "pnpm";
}

/**
 * Spawn the agent-deck server and resolve with the port it actually bound.
 * We pass PORT=0 so Fastify picks a free ephemeral port itself and reports it
 * in its startup log — no pre-pick, so there's no window for another process
 * to steal the port between choosing and binding it.
 */
function startServer() {
  return new Promise((resolve, reject) => {
    const child = spawn(pnpmCommand(), ["--filter", "@agent-deck/server", "dev"], {
      cwd: repoRoot,
      env: { ...process.env, PORT: "0" },
      // Pipe (not inherit) so the child holds pipes to us, not our raw stdout fds
      // — otherwise a detached child keeps our stdout open and blocks a clean exit.
      stdio: ["ignore", "pipe", "pipe"],
      // pnpm.cmd on Windows needs a shell to resolve. On POSIX, run the server in
      // its own process group so we can kill the whole tree (pnpm → tsx → node).
      shell: process.platform === "win32",
      detached: process.platform !== "win32",
    });
    serverProcess = child;

    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      reject(new Error("server did not report a port within 25s"));
    }, 25_000);

    child.stdout?.on("data", (chunk) => {
      process.stdout.write(chunk);
      if (settled) return;
      const match = /listening on http:\/\/127\.0\.0\.1:(\d+)/.exec(chunk.toString());
      if (match) {
        settled = true;
        clearTimeout(timer);
        resolve(Number(match[1]));
      }
    });
    child.stderr?.on("data", (chunk) => process.stderr.write(chunk));

    child.on("exit", (code) => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        reject(new Error(`server exited (code ${code}) before it started listening`));
        return;
      }
      // Died after starting, while the app is up → tear the app down rather than
      // leave a dead window pointed at nothing.
      if (!app.isQuiting && code !== 0 && code !== null) {
        dialog.showErrorBox(
          "agent-deck server stopped",
          `The backend exited with code ${code}. Check the terminal for details.`,
        );
        app.quit();
      }
    });
  });
}

/** Kill the whole server process tree (pnpm → tsx → node), cross-platform. */
function stopServer() {
  const child = serverProcess;
  if (!child || child.killed || child.pid == null) return;
  if (process.platform === "win32") {
    // SYNCHRONOUS so the whole tree (pnpm → tsx → node) is actually reaped before
    // this returns and `before-quit` lets Electron exit. A fire-and-forget spawn
    // let Electron quit while taskkill was still running, orphaning the server —
    // its lingering handles then blocked the Playwright worker teardown on Windows
    // ("Worker teardown timeout of 90000ms exceeded"). Capped so a stuck taskkill
    // can't hang quit.
    spawnSync("taskkill", ["/pid", String(child.pid), "/T", "/F"], {
      stdio: "ignore",
      timeout: 5_000,
    });
  } else {
    try {
      // Negative pid → the detached process group, so the tsx/node grandchild dies too.
      process.kill(-child.pid, "SIGTERM");
    } catch {
      child.kill("SIGTERM");
    }
  }
}

/** Poll GET /health until the server answers or we time out. */
function waitForHealth(port, timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs;
  const url = `http://127.0.0.1:${port}/health`;
  return new Promise((resolve, reject) => {
    const attempt = () => {
      const req = http.get(url, (res) => {
        res.resume();
        if (res.statusCode === 200) resolve();
        else retry();
      });
      req.on("error", retry);
      req.setTimeout(1500, () => req.destroy());
    };
    const retry = () => {
      if (Date.now() > deadline) reject(new Error("server did not become healthy in time"));
      else setTimeout(attempt, 250);
    };
    attempt();
  });
}

function createWindow(port) {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 860,
    minWidth: 940,
    minHeight: 600,
    backgroundColor: WINDOW_BG,
    titleBarStyle: process.platform === "darwin" ? "hiddenInset" : "hidden",
    titleBarOverlay:
      process.platform === "darwin"
        ? undefined
        : { color: TITLEBAR_BG, symbolColor: TITLEBAR_SYMBOL, height: 40 },
    autoHideMenuBar: process.platform !== "darwin",
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      sandbox: true,
    },
  });

  // AGENT_DECK_RENDERER_URL points at the Vite dev server (HMR) when set;
  // otherwise load the server-served production build same-origin.
  const rendererUrl = process.env.AGENT_DECK_RENDERER_URL || `http://127.0.0.1:${port}/`;
  void mainWindow.loadURL(rendererUrl);

  // Open external links (docs, GitHub) in the user's browser, not the app.
  // Parse the URL and compare the exact host so a look-alike like
  // http://127.0.0.1.evil.test can't pass, and only ever hand http(s) to the OS.
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    let parsed;
    try {
      parsed = new URL(url);
    } catch {
      return { action: "deny" };
    }
    if (parsed.hostname === "127.0.0.1" || parsed.hostname === "localhost") {
      return { action: "allow" };
    }
    if (parsed.protocol === "http:" || parsed.protocol === "https:") {
      void shell.openExternal(url);
    }
    return { action: "deny" };
  });

  mainWindow.on("closed", () => {
    mainWindow = null;
  });
}

/** Route a menu command to the renderer, which owns the actual action. */
function sendMenu(action) {
  mainWindow?.webContents.send("menu", action);
}

/** Native application menu — File actions bridge to the renderer via IPC. */
function buildAppMenu() {
  const isMac = process.platform === "darwin";
  const template = [
    ...(isMac ? [{ role: "appMenu" }] : []),
    {
      id: "menu-file",
      label: "File",
      submenu: [
        { label: "New Chat", accelerator: "CmdOrCtrl+N", click: () => sendMenu("new-chat") },
        {
          label: "Add Project…",
          accelerator: "CmdOrCtrl+Alt+O",
          click: () => sendMenu("add-project"),
        },
        { type: "separator" },
        // Stable, non-rebindable way into the keybindings editor. The command
        // palette is the only OTHER entry point and its open-chord is itself
        // user-rebindable, so without this a lost palette binding would leave no
        // in-app path to reopen the editor and reset it. Deliberately given no
        // accelerator so it can't shadow any user-bound app chord.
        { label: "Edit Keybindings…", click: () => sendMenu("open-keybindings") },
        { type: "separator" },
        isMac ? { role: "close" } : { role: "quit" },
      ],
    },
    { id: "menu-edit", role: "editMenu" },
    // Dev keeps the full View menu (reload/devtools handy); a shipped build gets
    // only the user-facing zoom/fullscreen controls.
    app.isPackaged
      ? {
          id: "menu-view",
          label: "View",
          submenu: [
            { role: "resetZoom" },
            { role: "zoomIn" },
            { role: "zoomOut" },
            { type: "separator" },
            { role: "togglefullscreen" },
          ],
        }
      : { id: "menu-view", role: "viewMenu" },
    { role: "windowMenu" },
    {
      id: "menu-help",
      label: "Help",
      submenu: [
        {
          label: "Agent Deck on GitHub",
          click: () => void shell.openExternal("https://github.com/a-streetcoder/agent-deck"),
        },
        {
          label: "Documentation",
          click: () =>
            void shell.openExternal(
              "https://github.com/a-streetcoder/agent-deck/tree/main/agent-deck-documentation",
            ),
        },
        { type: "separator" },
        { role: "about", label: "About Agent Deck" },
      ],
    },
  ];
  return Menu.buildFromTemplate(template);
}

/** Native folder chooser (the NSOpenPanel equivalent) for the project flow. */
ipcMain.handle("dialog:openDirectory", async (_event, options = {}) => {
  const properties = ["openDirectory", "createDirectory"];
  if (options.multiple) properties.push("multiSelections");
  const result = await dialog.showOpenDialog(mainWindow ?? undefined, {
    title: options.title ?? "Choose Folder",
    message: options.message,
    buttonLabel: options.buttonLabel,
    properties,
  });
  if (result.canceled) return [];
  return result.filePaths;
});

/** Open a renderer titlebar button's native menu directly below the top bar. */
ipcMain.handle("app-menu:open", (_event, menuName, anchor) => {
  const name = String(menuName ?? "").toLowerCase();
  if (!new Set(["file", "edit", "view", "help"]).has(name)) {
    throw new Error("Unknown application menu");
  }
  const item = Menu.getApplicationMenu()?.getMenuItemById(`menu-${name}`);
  if (!item?.submenu) throw new Error("Application menu is unavailable");
  if (!mainWindow || !anchor || !Number.isFinite(anchor.x) || !Number.isFinite(anchor.y)) {
    throw new Error("Application menu anchor is invalid");
  }
  const [contentWidth, contentHeight] = mainWindow.getContentSize();
  const x = Math.max(0, Math.min(contentWidth, Math.round(anchor.x)));
  const y = Math.max(0, Math.min(contentHeight, Math.round(anchor.y)));
  item.submenu.popup({ window: mainWindow, x, y });
  return true;
});

async function bootstrap() {
  try {
    serverPort = await startServer();
    await waitForHealth(serverPort);
  } catch (error) {
    dialog.showErrorBox("agent-deck failed to start", String(error));
    app.quit();
    return;
  }
  app.setAboutPanelOptions({
    applicationName: "Agent Deck",
    applicationVersion: app.getVersion(),
    credits: "A native harness for the pi coding agent.",
  });
  Menu.setApplicationMenu(buildAppMenu());
  createWindow(serverPort);
}

app.whenReady().then(bootstrap);

app.on("activate", () => {
  // macOS: re-open a window when the dock icon is clicked and none are open.
  if (BrowserWindow.getAllWindows().length === 0 && serverPort) {
    createWindow(serverPort);
  }
});

app.on("window-all-closed", () => {
  app.quit();
});

app.on("before-quit", () => {
  app.isQuiting = true;
  stopServer();
});
