import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import spawn from "cross-spawn";
import { PiNotFoundError, resolvePiBinary } from "./resolve.ts";

/**
 * Environment health probe (native Doctor screen): is pi installed, what
 * version, and which providers have credentials. Auth is read as
 * presence-only from ~/.pi/agent/auth.json — never the credential values.
 */

export type CheckStatus = "ok" | "warn" | "error";

export interface HealthCheck {
  id: string;
  label: string;
  status: CheckStatus;
  detail: string;
  /** A copyable shell command that fixes the check (native Doctor Fix action). */
  fixCommand?: string;
}

export interface DoctorReport {
  checks: HealthCheck[];
  /** Provider ids that have a credential entry (no secrets). */
  signedInProviders: string[];
}

/** pi's minimum supported Node (package.json engines: node >=22.19.0). */
export const MIN_NODE_VERSION = "22.19.0";
const MIN_NODE_PARTS = MIN_NODE_VERSION.split(".").map(Number) as [number, number, number];

/**
 * Parse `v22.19.0` (or `22.19.0`) → [22,19,0]; null if unrecognizable. The
 * `(?![.\d])` boundary rejects an extra numeric segment (`22.19.0.1`) so a
 * malformed string isn't misread as a clean release, while still allowing a
 * trailing prerelease/build suffix (`-nightly`, `+build`) or ` (extra text)` —
 * the base X.Y.Z is what the minimum is compared against.
 */
export function parseNodeVersion(raw: string | null): [number, number, number] | null {
  if (!raw) return null;
  const match = raw.trim().match(/^v?(\d+)\.(\d+)\.(\d+)(?![.\d])/);
  if (!match) return null;
  return [Number(match[1]), Number(match[2]), Number(match[3])];
}

/**
 * A compact human summary of the notable bits of a parsed pi settings.json
 * (native Doctor "Settings Files": builtin-agent overrides, disableBuiltins,
 * packages, extra prompt-template paths). Purely read-only and fully defensive
 * against missing/mistyped fields; returns "" when nothing notable is set.
 */
export function summarizeSettings(parsed: unknown): string {
  if (typeof parsed !== "object" || parsed === null) return "";
  const s = parsed as Record<string, unknown>;
  // Only a plain (non-array) object counts — subagents / agentOverrides are
  // `{...}` maps, never arrays, so a wrong-shaped array value must NOT be counted
  // by its indices.
  const asObject = (v: unknown): Record<string, unknown> =>
    typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
  const plural = (n: number, one: string): string => `${n} ${one}${n === 1 ? "" : "s"}`;

  const parts: string[] = [];
  const subagents = asObject(s.subagents);
  const overrideCount = Object.keys(asObject(subagents.agentOverrides)).length;
  if (overrideCount > 0) parts.push(plural(overrideCount, "agent override"));
  if (subagents.disableBuiltins === true) parts.push("builtin agents disabled");
  const packageCount = Array.isArray(s.packages) ? s.packages.length : 0;
  if (packageCount > 0) parts.push(plural(packageCount, "package"));
  const promptCount = Array.isArray(s.prompts) ? s.prompts.length : 0;
  if (promptCount > 0) parts.push(plural(promptCount, "extra prompt path"));
  return parts.join(", ");
}

/** True iff the given version is >= MIN_NODE_VERSION (lexicographic by part). */
export function meetsMinNode(version: [number, number, number]): boolean {
  for (let i = 0; i < 3; i++) {
    if (version[i]! > MIN_NODE_PARTS[i]!) return true;
    if (version[i]! < MIN_NODE_PARTS[i]!) return false;
  }
  return true; // exactly equal
}

/**
 * Run `cmd --version` (or the given args) and return its first stdout line, or
 * null if the command is missing or fails. cross-spawn, not node's execFile: on
 * Windows the resolved binary may be an npm `.cmd` shim, and Node refuses to run
 * .cmd/.bat via execFile without shell:true (CVE-2024-27980 mitigation → EINVAL);
 * cross-spawn rewrites the invocation — the same mechanism PiProcess relies on.
 */
function probeVersion(cmd: string, args: string[] = ["--version"]): Promise<string | null> {
  return new Promise((resolve) => {
    let child: ReturnType<typeof spawn>;
    try {
      child = spawn(cmd, args, { stdio: ["ignore", "pipe", "ignore"] });
    } catch {
      resolve(null);
      return;
    }
    let stdout = "";
    let settled = false;
    const settle = (value: string | null): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(value);
    };
    // Resolve on the timeout itself — killing alone doesn't guarantee a 'close'
    // if the child ignores SIGTERM, which would hang runDoctor forever.
    const timer = setTimeout(() => {
      child.kill();
      settle(null);
    }, 10_000);
    child.stdout?.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
    });
    child.on("error", () => settle(null));
    child.on("close", (code) => {
      const first = stdout.trim().split("\n")[0];
      settle(code === 0 && first ? first : null);
    });
  });
}

/**
 * Run a command purely for its exit status (e.g. `gh auth status`), resolving
 * true iff it exits 0. Same cross-spawn / timeout handling as probeVersion.
 */
function probeSuccess(cmd: string, args: string[]): Promise<boolean> {
  return new Promise((resolve) => {
    let child: ReturnType<typeof spawn>;
    try {
      child = spawn(cmd, args, { stdio: "ignore" });
    } catch {
      resolve(false);
      return;
    }
    let settled = false;
    const settle = (value: boolean): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(value);
    };
    const timer = setTimeout(() => {
      child.kill();
      settle(false);
    }, 10_000);
    child.on("error", () => settle(false));
    child.on("close", (code) => settle(code === 0));
  });
}

function readSignedInProviders(home: string): string[] {
  const authFile = path.join(home, ".pi", "agent", "auth.json");
  try {
    const parsed: unknown = JSON.parse(readFileSync(authFile, "utf8"));
    if (typeof parsed === "object" && parsed !== null) {
      // auth.json is a map keyed by provider id; presence = signed in.
      return Object.keys(parsed as Record<string, unknown>).sort();
    }
  } catch {
    // Missing/unreadable — no providers.
  }
  return [];
}

export async function runDoctor(home: string = homedir()): Promise<DoctorReport> {
  const checks: HealthCheck[] = [];

  let binPath: string | null = null;
  let binSource = "";
  try {
    const resolved = resolvePiBinary();
    binPath = resolved.path;
    binSource = resolved.source;
    checks.push({
      id: "pi-binary",
      label: "pi binary",
      status: "ok",
      detail: `${resolved.path} (via ${resolved.source})`,
    });
  } catch (error) {
    checks.push({
      id: "pi-binary",
      label: "pi binary",
      status: "error",
      detail: error instanceof PiNotFoundError ? error.message : String(error),
      fixCommand: "npm install -g @earendil-works/pi-coding-agent",
    });
  }

  if (binPath) {
    const version = await probeVersion(binPath);
    checks.push({
      id: "pi-version",
      label: "pi version",
      status: version ? "ok" : "warn",
      detail: version ?? "could not read --version",
    });
    void binSource;
  }

  // Node.js runtime: pi is an npm-installed Node CLI (spawned via cross-spawn),
  // so it can't run without Node on PATH — and it requires a minimum version
  // (package.json engines). A "pi binary found" check alone would look healthy
  // while pi fails to launch, so Node is a first-class preflight.
  const nodeVersion = await probeVersion("node");
  const nodeParsed = parseNodeVersion(nodeVersion);
  if (!nodeVersion) {
    checks.push({
      id: "node",
      label: "Node.js runtime",
      status: "error",
      detail: `node not on PATH — pi is a Node CLI and needs Node.js ≥ ${MIN_NODE_VERSION} (install from nodejs.org)`,
    });
  } else if (nodeParsed && !meetsMinNode(nodeParsed)) {
    checks.push({
      id: "node",
      label: "Node.js runtime",
      status: "error",
      detail: `${nodeVersion} — pi requires Node.js ≥ ${MIN_NODE_VERSION}; upgrade Node`,
    });
  } else {
    checks.push({
      id: "node",
      label: "Node.js runtime",
      status: "ok",
      detail: nodeParsed ? `${nodeVersion} (≥ ${MIN_NODE_VERSION})` : nodeVersion,
    });
  }

  // bash on PATH: pi's shell tools run through bash, which is native on
  // macOS/Linux but must come from Git Bash on Windows — a common cross-platform
  // gotcha, so it is a first-class preflight check.
  const bashVersion = await probeVersion("bash");
  const onWindows = process.platform === "win32";
  checks.push({
    id: "bash",
    label: "bash shell",
    status: bashVersion ? "ok" : "error",
    detail: bashVersion
      ? bashVersion
      : onWindows
        ? "bash not on PATH — install Git Bash and add it to PATH (pi's shell tools need bash)"
        : "bash not on PATH — pi's shell tools need bash",
  });

  // git: pi's version-control tools (and Agent Deck's fork/worktree flows) need it.
  const gitVersion = await probeVersion("git");
  checks.push({
    id: "git",
    label: "git",
    status: gitVersion ? "ok" : "warn",
    detail: gitVersion ?? "git not on PATH — version-control tools will be unavailable",
  });

  // GitHub CLI: the Issues screen shells out to `gh`, which must be installed
  // AND authenticated. Honors the same AGENT_DECK_GH_BIN override the Issues
  // routes use, so it can be exercised hermetically.
  const ghBin = process.env.AGENT_DECK_GH_BIN || "gh";
  const ghVersion = await probeVersion(ghBin);
  if (!ghVersion) {
    checks.push({
      id: "github",
      label: "GitHub CLI",
      status: "warn",
      detail: "gh not on PATH — the Issues screen needs the GitHub CLI (install gh)",
    });
  } else {
    const authed = await probeSuccess(ghBin, ["auth", "status"]);
    checks.push({
      id: "github",
      label: "GitHub CLI",
      status: authed ? "ok" : "warn",
      detail: authed
        ? `${ghVersion} — authenticated`
        : `${ghVersion} — installed but not authenticated (run: gh auth login)`,
      fixCommand: authed ? undefined : "gh auth login",
    });
  }

  const signedInProviders = readSignedInProviders(home);
  const authFile = path.join(home, ".pi", "agent", "auth.json");
  checks.push({
    id: "auth",
    label: "Provider credentials",
    status: signedInProviders.length > 0 ? "ok" : "warn",
    detail:
      signedInProviders.length > 0
        ? `${signedInProviders.length} provider(s): ${signedInProviders.join(", ")}`
        : existsSync(authFile)
          ? "auth.json present but no providers"
          : "no auth.json — sign in with pi first",
    // A provider API key is the simplest fix (native Doctor "Add …_API_KEY").
    // The placeholder avoids shell metacharacters so it's safe to paste as-is.
    fixCommand: signedInProviders.length > 0 ? undefined : "export ANTHROPIC_API_KEY=YOUR_KEY_HERE",
  });

  // pi's settings.json (native Doctor "Settings Files"): pi's SettingsManager
  // reads ~/.pi/agent/settings.json on startup with strict JSON.parse. Absent is
  // fine (pi uses defaults). A malformed file does NOT crash pi — it catches the
  // parse error, falls back to {}, and emits a warning-level diagnostic — but the
  // user's custom settings are then silently dropped, so it's a "warn" (matching
  // pi's own severity), not an "error". Never writes/exposes the contents.
  const settingsPath = path.join(home, ".pi", "agent", "settings.json");
  if (!existsSync(settingsPath)) {
    checks.push({
      id: "settings",
      label: "pi settings.json",
      status: "ok",
      detail: "not present — pi uses built-in defaults",
    });
  } else {
    let parsed: unknown;
    let valid = true;
    try {
      parsed = JSON.parse(readFileSync(settingsPath, "utf8"));
    } catch {
      valid = false;
    }
    if (valid) {
      // Surface a read-only summary of the notable bits (native "Settings Files").
      const summary = summarizeSettings(parsed);
      checks.push({
        id: "settings",
        label: "pi settings.json",
        status: "ok",
        detail: summary ? `valid JSON — ${summary}` : "valid JSON",
      });
    } else {
      checks.push({
        id: "settings",
        label: "pi settings.json",
        status: "warn",
        detail: `malformed JSON at ${settingsPath} — pi ignores it and falls back to built-in defaults, so your custom settings won't apply; fix or remove it`,
      });
    }
  }

  return { checks, signedInProviders };
}
