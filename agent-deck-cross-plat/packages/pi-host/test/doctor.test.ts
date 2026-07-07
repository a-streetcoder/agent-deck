import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { runDoctor } from "../src/doctor.ts";

/**
 * The environment doctor probes real host tools. bash + git are cross-platform
 * prerequisites for pi's shell / version-control tools (bash comes from Git Bash
 * on Windows), and the Issues screen needs an authenticated GitHub CLI — so the
 * report surfaces each as a first-class check.
 */

describe("runDoctor", () => {
  it("includes a bash and a git preflight check with a verdict", async () => {
    const home = mkdtempSync(path.join(tmpdir(), "doctor-home-"));
    const report = await runDoctor(home);
    const byId = new Map(report.checks.map((c) => [c.id, c]));

    // Both checks are surfaced with a verdict + a non-empty detail. Their exact
    // ok/warn/error is the host's truth, not something to hardcode — a valid host
    // could legitimately lack git or (on Windows) Git Bash.
    for (const id of ["bash", "git"]) {
      const check = byId.get(id);
      expect(check, `${id} check present`).toBeDefined();
      expect(check!.detail).not.toBe("");
      expect(["ok", "warn", "error"]).toContain(check!.status);
    }
  });
});

/** A gh stub: `--version` succeeds; `auth status` exits with `authExit`. */
function ghStub(authExit: number): string {
  const stub = path.join(mkdtempSync(path.join(tmpdir(), "gh-stub-")), "gh");
  writeFileSync(
    stub,
    `#!/bin/sh
if [ "$1" = "--version" ]; then echo "gh version 2.40.0"; exit 0; fi
if [ "$1" = "auth" ]; then exit ${authExit}; fi
exit 0
`,
  );
  chmodSync(stub, 0o755);
  return stub;
}

// The stub is a unix shell script; on Windows gh runs natively. The ubuntu/macos
// runners cover this leg (mirrors the Issues gh-stub precedent).
describe.skipIf(process.platform === "win32")("runDoctor GitHub CLI check", () => {
  afterEach(() => {
    delete process.env.AGENT_DECK_GH_BIN;
  });

  async function githubCheck() {
    const report = await runDoctor(mkdtempSync(path.join(tmpdir(), "doctor-home-")));
    return report.checks.find((c) => c.id === "github")!;
  }

  it("is ok when gh is installed and authenticated", async () => {
    process.env.AGENT_DECK_GH_BIN = ghStub(0);
    const check = await githubCheck();
    expect(check.status).toBe("ok");
    expect(check.detail).toContain("authenticated");
  });

  it("warns when gh is installed but not authenticated", async () => {
    process.env.AGENT_DECK_GH_BIN = ghStub(1);
    const check = await githubCheck();
    expect(check.status).toBe("warn");
    expect(check.detail).toContain("not authenticated");
  });

  it("warns when gh is not on PATH", async () => {
    process.env.AGENT_DECK_GH_BIN = path.join(tmpdir(), "definitely-no-such-gh-binary");
    const check = await githubCheck();
    expect(check.status).toBe("warn");
    expect(check.detail).toContain("not on PATH");
  });
});
