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

import { spawn } from "node:child_process";
import { createServer } from "node:net";
import http from "node:http";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { app, BrowserWindow, dialog, ipcMain, shell } from "electron";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
// apps/desktop -> repo root (agent-deck-cross-plat).
const repoRoot = path.resolve(__dirname, "..", "..");

/** Background dark so there's no white flash before the UI paints. */
const WINDOW_BG = "#0f1115";

let serverProcess = null;
let serverPort = null;
let mainWindow = null;

/** Ask the OS for an unused TCP port so we never collide with a stray server. */
function getFreePort() {
  return new Promise((resolve, reject) => {
    const probe = createServer();
    probe.unref();
    probe.on("error", reject);
    probe.listen(0, "127.0.0.1", () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });
}

/** Resolve pnpm's executable name per platform (dev PATH is inherited). */
function pnpmCommand() {
  return process.platform === "win32" ? "pnpm.cmd" : "pnpm";
}

/** Spawn the agent-deck server on `port`, serving the built web app. */
function startServer(port) {
  const child = spawn(pnpmCommand(), ["--filter", "@agent-deck/server", "dev"], {
    cwd: repoRoot,
    env: { ...process.env, PORT: String(port) },
    // Pipe (not inherit) so the child holds pipes to us, not our raw stdout fds
    // — otherwise a detached child keeps our stdout open and blocks a clean exit.
    stdio: ["ignore", "pipe", "pipe"],
    // pnpm.cmd on Windows needs a shell to resolve. On POSIX, run the server in
    // its own process group so we can kill the whole tree (pnpm → tsx → node).
    shell: process.platform === "win32",
    detached: process.platform !== "win32",
  });
  child.stdout?.on("data", (chunk) => process.stdout.write(chunk));
  child.stderr?.on("data", (chunk) => process.stderr.write(chunk));
  child.on("exit", (code) => {
    // If the server dies unexpectedly while the app is up, tear the app down
    // rather than leave a dead window pointed at nothing.
    if (!app.isQuiting && code !== 0 && code !== null) {
      dialog.showErrorBox(
        "agent-deck server stopped",
        `The backend exited with code ${code}. Check the terminal for details.`,
      );
      app.quit();
    }
  });
  return child;
}

/** Kill the whole server process tree (pnpm → tsx → node), cross-platform. */
function stopServer() {
  const child = serverProcess;
  if (!child || child.killed || child.pid == null) return;
  if (process.platform === "win32") {
    spawn("taskkill", ["/pid", String(child.pid), "/T", "/F"], { stdio: "ignore" });
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
    titleBarStyle: process.platform === "darwin" ? "hiddenInset" : "default",
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
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith("http://127.0.0.1") || url.startsWith("http://localhost")) {
      return { action: "allow" };
    }
    void shell.openExternal(url);
    return { action: "deny" };
  });

  mainWindow.on("closed", () => {
    mainWindow = null;
  });
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

async function bootstrap() {
  const port = await getFreePort();
  serverPort = port;
  serverProcess = startServer(port);
  try {
    await waitForHealth(port);
  } catch (error) {
    dialog.showErrorBox("agent-deck failed to start", String(error));
    app.quit();
    return;
  }
  createWindow(port);
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
