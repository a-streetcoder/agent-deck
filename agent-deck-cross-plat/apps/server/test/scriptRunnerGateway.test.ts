import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Layer, ManagedRuntime } from "effect";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { ServerRuntime } from "../src/runtime.ts";
import { createScriptRunnerGateway, ScriptAlreadyRunning } from "../src/scriptRunnerGateway.ts";
import {
  makeScriptRunner,
  ScriptRunner,
  type ScriptAdapter,
  type ScriptExit,
} from "../src/services/scriptRunner.ts";

/**
 * ScriptRunnerGateway unit tests against a fake adapter — the one-running-script-
 * per-session guard (+ its release when a run exits on its own), the shutdown
 * sweep `closeAll()` (run scopes are detached roots, like terminals), and
 * server-allocated run ids. A scratch `package.json` provides the declared
 * command so the real resolution path runs while the fake adapter owns the
 * (no-op) process lifecycle.
 */

interface FakeChildRecord {
  kills: Array<"SIGTERM" | "SIGKILL">;
  emitExit: (exit: ScriptExit) => void;
}

function fakeRuntime(): { runtime: ServerRuntime; children: FakeChildRecord[] } {
  const children: FakeChildRecord[] = [];
  const adapter: ScriptAdapter = {
    spawn: () => {
      let exitCallback: ((event: ScriptExit) => void) | null = null;
      const record: FakeChildRecord = {
        kills: [],
        emitExit: (exit) => exitCallback?.(exit),
      };
      children.push(record);
      return {
        pid: 5252,
        kill: (signal) => {
          record.kills.push(signal);
          exitCallback?.({ exitCode: 0, signal });
        },
        onData: () => () => {},
        onExit: (callback) => {
          exitCallback = callback;
          return () => {
            exitCallback = null;
          };
        },
      };
    },
  };
  const runtime = ManagedRuntime.make(
    Layer.succeed(ScriptRunner, makeScriptRunner(adapter)),
  ) as unknown as ServerRuntime;
  return { runtime, children };
}

describe("createScriptRunnerGateway", () => {
  let dir: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "agent-deck-gw-"));
    writeFileSync(join(dir, "package.json"), JSON.stringify({ scripts: { dev: "noop" } }));
  });
  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it("resolves an undeclared script name to a start rejection (never spawns)", async () => {
    const { runtime, children } = fakeRuntime();
    const gateway = createScriptRunnerGateway(runtime);
    await expect(
      gateway.start({ sessionId: "s1", scriptName: "missing", cwd: dir }),
    ).rejects.toMatchObject({ _tag: "ScriptNotDeclared" });
    expect(children).toEqual([]);
  });

  it("allocates run ids, guards one-per-session, and releases the guard on exit", async () => {
    const { runtime, children } = fakeRuntime();
    const gateway = createScriptRunnerGateway(runtime);

    const run1 = await gateway.start({ sessionId: "s1", scriptName: "dev", cwd: dir });
    expect(run1.runId).toBe("run-1");
    // A second start for the same session is rejected while the first runs.
    await expect(
      gateway.start({ sessionId: "s1", scriptName: "dev", cwd: dir }),
    ).rejects.toBeInstanceOf(ScriptAlreadyRunning);

    // The child exits on its own → the per-session guard is released, so a fresh
    // run can start for the same session.
    children[0]!.emitExit({ exitCode: 0, signal: null });
    const run2 = await gateway.start({ sessionId: "s1", scriptName: "dev", cwd: dir });
    expect(run2.runId).toBe("run-2");
  });

  it("closeAll() tree-kills every still-open run and is idempotent", async () => {
    const { runtime, children } = fakeRuntime();
    const gateway = createScriptRunnerGateway(runtime);
    await gateway.start({ sessionId: "s1", scriptName: "dev", cwd: dir });
    await gateway.start({ sessionId: "s2", scriptName: "dev", cwd: dir });

    await gateway.closeAll();
    expect(children.map((c) => c.kills)).toEqual([["SIGTERM"], ["SIGTERM"]]);
    await gateway.closeAll();
    expect(children.map((c) => c.kills)).toEqual([["SIGTERM"], ["SIGTERM"]]);
  });

  it("closeAll() after a per-run close() never double-kills (memoized close)", async () => {
    const { runtime, children } = fakeRuntime();
    const gateway = createScriptRunnerGateway(runtime);
    const first = await gateway.start({ sessionId: "s1", scriptName: "dev", cwd: dir });
    await gateway.start({ sessionId: "s2", scriptName: "dev", cwd: dir });

    await first.close();
    expect(children[0]!.kills).toEqual(["SIGTERM"]);
    await gateway.closeAll();
    expect(children[0]!.kills).toEqual(["SIGTERM"]);
    expect(children[1]!.kills).toEqual(["SIGTERM"]);
  });
});
