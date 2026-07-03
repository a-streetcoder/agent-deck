import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { buildLaunchArgs } from "../src/launchPlan.ts";
import { PiSession } from "../src/PiSession.ts";
import { resolvePiBinary } from "../src/resolve.ts";

/**
 * Slice-2 gate: spawn a REAL user-installed pi binary in RPC mode and do a
 * get_state round-trip. Fully isolated launch (no session file, no tools, no
 * resources) so it never touches user data and needs no API key.
 */

const resolved = resolvePiBinary();
const cwd = mkdtempSync(path.join(tmpdir(), "pi-host-it-"));

const session = new PiSession({
  binPath: resolved.path,
  args: buildLaunchArgs({ kind: "helper", systemPrompt: "You are a connectivity test." }),
  cwd,
  env: { PI_SKIP_VERSION_CHECK: "1" },
  requestTimeoutMs: 30_000,
});

afterAll(async () => {
  await session.stop();
});

describe(`real pi RPC round-trip (${resolved.path}, source: ${resolved.source})`, () => {
  it("responds to get_state with a session id and idle streaming state", async () => {
    session.start();
    const state = await session.getState();
    expect(typeof state.sessionId).toBe("string");
    expect(state.sessionId.length).toBeGreaterThan(0);
    expect(state.isStreaming).toBe(false);
    // Helper launches are ephemeral: no session file may be created.
    expect(state.sessionFile ?? undefined).toBeUndefined();
  });

  it("responds to get_commands with no ambient resources loaded", async () => {
    const commands = await session.getCommands();
    expect(Array.isArray(commands)).toBe(true);
    // --no-extensions/--no-skills/--no-prompt-templates: nothing ambient may leak in.
    const fromAmbient = commands.filter((c) => c.source === "skill" || c.source === "prompt");
    expect(fromAmbient).toEqual([]);
  });

  it("stops cleanly", async () => {
    const exit = await session.stop();
    expect(session.isRunning).toBe(false);
    expect(exit).toBeDefined();
  });
});
