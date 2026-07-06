import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { runDoctor } from "../src/doctor.ts";

/**
 * The environment doctor probes real host tools. bash + git are cross-platform
 * prerequisites for pi's shell / version-control tools (bash comes from Git Bash
 * on Windows), so the report must surface them as first-class checks.
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
