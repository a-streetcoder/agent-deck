import { accessSync, constants, existsSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Discovery of the user-installed `pi` binary.
 *
 * Order (ported from the native app's PiExecutableResolver.swift and attempt #1's
 * pi_resolver.rs): explicit env override, then PATH, then well-known install locations.
 */

export const PI_INSTALL_HINT =
  "Install pi with: npm install -g @earendil-works/pi-coding-agent " +
  "(or set AGENT_DECK_PI_PATH to the pi binary).";

export class PiNotFoundError extends Error {}

export interface ResolvedPi {
  path: string;
  source: "env" | "path" | "bundled" | "candidate";
}

const WINDOWS_EXTENSIONS = [".cmd", ".exe", ".bat", ".ps1", ""];

function isExecutableFile(filePath: string): boolean {
  try {
    const stat = statSync(filePath);
    if (!stat.isFile()) return false;
    if (process.platform !== "win32") {
      accessSync(filePath, constants.X_OK);
    }
    return true;
  } catch {
    return false;
  }
}

function findInDir(dir: string, platform: NodeJS.Platform): string | undefined {
  const names = platform === "win32" ? WINDOWS_EXTENSIONS.map((ext) => `pi${ext}`) : ["pi"];
  for (const name of names) {
    const candidate = path.join(dir, name);
    if (isExecutableFile(candidate)) return candidate;
  }
  return undefined;
}

/**
 * The pinned pi's own `.bin` locations. pi is a dependency of THIS package, so
 * its executable symlink lives in pi-host's node_modules (and, when hoisted,
 * the workspace root's). Searching these makes pi resolvable even when it isn't
 * on the current script's PATH — e.g. a workspace script run from a package
 * (like apps/server) whose PATH doesn't include pi under a strict CI install.
 */
function bundledBinDirs(): string[] {
  try {
    const here = path.dirname(fileURLToPath(import.meta.url));
    const piHostRoot = path.resolve(here, ".."); // packages/pi-host
    return [
      path.join(piHostRoot, "node_modules", ".bin"),
      path.resolve(piHostRoot, "..", "..", "node_modules", ".bin"), // workspace root
    ];
  } catch {
    return [];
  }
}

function unixCandidateDirs(home: string): string[] {
  const dirs = [
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
    path.join(home, ".pi/agent/bin"),
    path.join(home, ".volta/bin"),
    path.join(home, ".bun/bin"),
    path.join(home, ".local/bin"),
    path.join(home, ".npm-global/bin"),
    path.join(home, ".nvm/versions/node/current/bin"),
  ];
  // Enumerate concrete nvm and fnm version dirs.
  for (const root of [
    path.join(home, ".nvm/versions/node"),
    path.join(home, ".local/share/fnm/node-versions"),
  ]) {
    try {
      for (const entry of readdirSync(root)) {
        dirs.push(path.join(root, entry, "bin"));
        dirs.push(path.join(root, entry, "installation", "bin"));
      }
    } catch {
      // Root doesn't exist — skip.
    }
  }
  return dirs;
}

function windowsCandidateDirs(home: string, env: NodeJS.ProcessEnv): string[] {
  const dirs: string[] = [];
  if (env.APPDATA) dirs.push(path.join(env.APPDATA, "npm"));
  dirs.push(path.join(home, "AppData", "Roaming", "npm"));
  dirs.push(path.join(home, ".volta", "bin"));
  dirs.push(path.join(home, ".bun", "bin"));
  return dirs;
}

export function resolvePiBinary(
  env: NodeJS.ProcessEnv = process.env,
  platform: NodeJS.Platform = process.platform,
): ResolvedPi {
  // 1. Explicit overrides fail loudly when wrong — never silently fall through.
  for (const key of ["AGENT_DECK_PI_PATH", "PI_CLI_PATH"] as const) {
    const override = env[key]?.trim();
    if (override) {
      if (!existsSync(override)) {
        throw new PiNotFoundError(
          `${key} is set to "${override}" but no file exists there. ${PI_INSTALL_HINT}`,
        );
      }
      return { path: override, source: "env" };
    }
  }

  // 2. PATH lookup (the user's own pi wins when present).
  for (const dir of (env.PATH ?? "").split(path.delimiter)) {
    if (!dir) continue;
    const found = findInDir(dir, platform);
    if (found) return { path: found, source: "path" };
  }

  // 3. The pinned pi bundled as this package's dependency — resolves regardless
  // of PATH/hoisting (the CI case where pi isn't on a package script's PATH).
  for (const dir of bundledBinDirs()) {
    const found = findInDir(dir, platform);
    if (found) return { path: found, source: "bundled" };
  }

  // 4. Well-known install locations (covers GUI launches with a minimal PATH).
  const home = homedir();
  const dirs = platform === "win32" ? windowsCandidateDirs(home, env) : unixCandidateDirs(home);
  for (const dir of dirs) {
    const found = findInDir(dir, platform);
    if (found) return { path: found, source: "candidate" };
  }

  throw new PiNotFoundError(`Could not find the pi binary. ${PI_INSTALL_HINT}`);
}
