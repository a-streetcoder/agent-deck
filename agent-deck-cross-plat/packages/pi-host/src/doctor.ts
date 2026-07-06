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

async function piVersion(binPath: string): Promise<string | null> {
  // cross-spawn, not node's execFile: on Windows the resolved binary is the npm
  // `pi.cmd` shim, and Node refuses to run .cmd/.bat via execFile without
  // shell:true (the CVE-2024-27980 mitigation → EINVAL). cross-spawn rewrites
  // the invocation so the shim runs — the same mechanism PiProcess relies on.
  return new Promise((resolve) => {
    const child = spawn(binPath, ["--version"], { stdio: ["ignore", "pipe", "ignore"] });
    let stdout = "";
    const timer = setTimeout(() => child.kill(), 10_000);
    child.stdout?.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
    });
    child.on("error", () => {
      clearTimeout(timer);
      resolve(null);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      const first = stdout.trim().split("\n")[0];
      resolve(code === 0 && first ? first : null);
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
    const version = await piVersion(binPath);
    checks.push({
      id: "pi-version",
      label: "pi version",
      status: version ? "ok" : "warn",
      detail: version ?? "could not read --version",
    });
    void binSource;
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
  });

  return { checks, signedInProviders };
}
