import { chmodSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  MIN_NODE_VERSION,
  meetsMinNode,
  parseNodeVersion,
  runDoctor,
  summarizeSettings,
} from "../src/doctor.ts";

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

  it("validates pi's settings.json (native Doctor Settings Files)", async () => {
    // Absent → ok (pi uses defaults).
    const absent = mkdtempSync(path.join(tmpdir(), "doctor-home-"));
    const absentCheck = (await runDoctor(absent)).checks.find((c) => c.id === "settings");
    expect(absentCheck?.status).toBe("ok");
    expect(absentCheck?.detail).toMatch(/not present/i);

    // Valid but empty → ok, plain "valid JSON" (no summary).
    const good = mkdtempSync(path.join(tmpdir(), "doctor-home-"));
    const goodAgent = path.join(good, ".pi", "agent");
    mkdirSync(goodAgent, { recursive: true });
    writeFileSync(path.join(goodAgent, "settings.json"), '{"subagents":{"agentOverrides":{}}}');
    const goodCheck = (await runDoctor(good)).checks.find((c) => c.id === "settings");
    expect(goodCheck?.status).toBe("ok");
    expect(goodCheck?.detail).toBe("valid JSON");

    // Valid with notable content → ok, and the detail summarizes it (native
    // "Settings Files": overrides, disableBuiltins, packages, extra prompts).
    const rich = mkdtempSync(path.join(tmpdir(), "doctor-home-"));
    const richAgent = path.join(rich, ".pi", "agent");
    mkdirSync(richAgent, { recursive: true });
    writeFileSync(
      path.join(richAgent, "settings.json"),
      JSON.stringify({
        subagents: { agentOverrides: { coder: { description: "x" } }, disableBuiltins: true },
        packages: ["pkg-a"],
        prompts: ["a", "b"],
      }),
    );
    const richCheck = (await runDoctor(rich)).checks.find((c) => c.id === "settings");
    expect(richCheck?.status).toBe("ok");
    expect(richCheck?.detail).toContain("1 agent override");
    expect(richCheck?.detail).toContain("builtin agents disabled");
    expect(richCheck?.detail).toContain("1 package");
    expect(richCheck?.detail).toContain("2 extra prompt paths");

    // Malformed JSON → warn (pi doesn't crash — it falls back to {} and warns —
    // but the user's custom settings are silently dropped).
    const bad = mkdtempSync(path.join(tmpdir(), "doctor-home-"));
    const badAgent = path.join(bad, ".pi", "agent");
    mkdirSync(badAgent, { recursive: true });
    writeFileSync(path.join(badAgent, "settings.json"), "{ not: valid json, ");
    const badCheck = (await runDoctor(bad)).checks.find((c) => c.id === "settings");
    expect(badCheck?.status).toBe("warn");
    expect(badCheck?.detail).toMatch(/malformed/i);
    expect(badCheck?.detail).toMatch(/custom settings won't apply/i);
  });

  it("includes a Node.js runtime check (this runner meets pi's minimum)", async () => {
    const home = mkdtempSync(path.join(tmpdir(), "doctor-home-"));
    const report = await runDoctor(home);
    const node = report.checks.find((c) => c.id === "node");
    expect(node, "node check present").toBeDefined();
    expect(node!.detail).not.toBe("");
    // The test runner necessarily runs on Node ≥ pi's minimum, so this is "ok".
    expect(node!.status).toBe("ok");
    expect(node!.detail).toContain(MIN_NODE_VERSION);
  });
});

describe("summarizeSettings (native Settings Files summary)", () => {
  it("returns empty for non-objects, null, and an empty settings object", () => {
    expect(summarizeSettings(null)).toBe("");
    expect(summarizeSettings("nope")).toBe("");
    expect(summarizeSettings(42)).toBe("");
    expect(summarizeSettings({})).toBe("");
    expect(summarizeSettings({ subagents: {} })).toBe("");
  });

  it("counts overrides/packages/prompts and flags disableBuiltins, pluralizing", () => {
    expect(summarizeSettings({ subagents: { agentOverrides: { a: {} } } })).toBe(
      "1 agent override",
    );
    expect(summarizeSettings({ subagents: { agentOverrides: { a: {}, b: {} } } })).toBe(
      "2 agent overrides",
    );
    expect(summarizeSettings({ subagents: { disableBuiltins: true } })).toBe(
      "builtin agents disabled",
    );
    // disableBuiltins:false is not notable.
    expect(summarizeSettings({ subagents: { disableBuiltins: false } })).toBe("");
    expect(summarizeSettings({ packages: ["x", "y"], prompts: ["p"] })).toBe(
      "2 packages, 1 extra prompt path",
    );
  });

  it("is defensive against mistyped fields", () => {
    // Wrong types must not throw or count.
    expect(summarizeSettings({ subagents: "oops", packages: "nope", prompts: 3 })).toBe("");
    // A wrong-shaped agentOverrides ARRAY must be rejected (not counted by its
    // indices) — empty AND non-empty.
    expect(summarizeSettings({ subagents: { agentOverrides: [] } })).toBe("");
    expect(summarizeSettings({ subagents: { agentOverrides: ["x", "y"] } })).toBe("");
    // A subagents value that is itself an array is likewise not an object map.
    expect(summarizeSettings({ subagents: ["nope"] })).toBe("");
  });
});

describe("Node.js version gate (pi engines >= " + MIN_NODE_VERSION + ")", () => {
  it("parses v-prefixed and bare versions, rejecting junk", () => {
    expect(parseNodeVersion("v22.19.0")).toEqual([22, 19, 0]);
    expect(parseNodeVersion("24.3.1")).toEqual([24, 3, 1]);
    expect(parseNodeVersion("v20.11.1 (some build)")).toEqual([20, 11, 1]);
    expect(parseNodeVersion("not-a-version")).toBeNull();
    expect(parseNodeVersion(null)).toBeNull();
    // A prerelease/build suffix still yields the base X.Y.Z (so a prerelease of
    // an OLD version still trips the minimum): v20.0.0-nightly → below min.
    expect(parseNodeVersion("v20.0.0-nightly20240101")).toEqual([20, 0, 0]);
    expect(parseNodeVersion("v22.19.0+build")).toEqual([22, 19, 0]);
    // But an extra numeric segment is rejected (not a clean release string).
    expect(parseNodeVersion("22.19.0.1")).toBeNull();
  });

  it("accepts the exact minimum and anything newer, rejects older", () => {
    expect(meetsMinNode([22, 19, 0])).toBe(true); // exact minimum
    expect(meetsMinNode([22, 19, 1])).toBe(true); // newer patch
    expect(meetsMinNode([22, 20, 0])).toBe(true); // newer minor
    expect(meetsMinNode([23, 0, 0])).toBe(true); // newer major
    expect(meetsMinNode([24, 5, 2])).toBe(true);
    expect(meetsMinNode([22, 18, 9])).toBe(false); // older patch/minor
    expect(meetsMinNode([22, 0, 0])).toBe(false);
    expect(meetsMinNode([21, 99, 99])).toBe(false); // older major
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

  it("attaches a `gh auth login` fix command when installed but unauthenticated", async () => {
    process.env.AGENT_DECK_GH_BIN = ghStub(1);
    expect((await githubCheck()).fixCommand).toBe("gh auth login");
    process.env.AGENT_DECK_GH_BIN = ghStub(0);
    expect((await githubCheck()).fixCommand).toBeUndefined(); // authenticated → no fix
  });
});

describe("runDoctor fix commands", () => {
  it("offers a provider-key fix when no providers are signed in", async () => {
    const report = await runDoctor(mkdtempSync(path.join(tmpdir(), "doctor-home-")));
    const auth = report.checks.find((c) => c.id === "auth")!;
    // A fresh home has no auth.json → the check warns with a copyable fix.
    expect(auth.status).toBe("warn");
    expect(auth.fixCommand).toContain("API_KEY");
  });
});
