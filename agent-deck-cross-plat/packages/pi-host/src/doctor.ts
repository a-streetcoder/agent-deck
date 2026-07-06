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
}

export interface DoctorReport {
  checks: HealthCheck[];
  /** Provider ids that have a credential entry (no secrets). */
  signedInProviders: string[];
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
  });

  return { checks, signedInProviders };
}
