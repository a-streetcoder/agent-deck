import { cwd } from "node:process";
import type { LoopDefinition } from "@agent-deck/domain";
import { describe, expect, it } from "vitest";
import { LoopEngine } from "../src/loopEngine.ts";

/**
 * Loop engine control flow, hermetic: the agent executor is injected (no pi),
 * while the validation command runs FOR REAL (`exit 0` / `exit 1`) so the
 * exit-code stop condition is exercised end-to-end.
 */

function makeLoop(overrides: Partial<LoopDefinition> = {}): LoopDefinition {
  return {
    id: "x",
    name: "test",
    description: "",
    goal: "do the thing",
    structure: "singleAgent",
    agentName: undefined,
    maxIterations: 3,
    validationCommand: "exit 0",
    writeTarget: "artifactMarkdown",
    source: "user",
    filePath: "x",
    ...overrides,
  };
}

describe("loop engine (single-agent)", () => {
  it("stops on the first passing validation (exit 0)", async () => {
    let calls = 0;
    const engine = new LoopEngine({
      executeAgent: async () => {
        calls += 1;
        return "agent output";
      },
    });
    const run = engine.start(makeLoop({ validationCommand: "exit 0", maxIterations: 5 }), cwd());
    await engine.settled(run.id);
    expect(run.status).toBe("completed");
    expect(run.stopReason).toBe("success");
    expect(calls).toBe(1); // stopped after the first passing iteration
    expect(run.iterations).toHaveLength(1);
    expect(run.iterations[0]).toMatchObject({ index: 1, validationPassed: true });
    expect(run.endedAt).toBeDefined();
  });

  it("runs every iteration then fails when validation never passes (exit 1)", async () => {
    let calls = 0;
    const engine = new LoopEngine({
      executeAgent: async () => {
        calls += 1;
        return "out";
      },
    });
    const run = engine.start(makeLoop({ validationCommand: "exit 1", maxIterations: 3 }), cwd());
    await engine.settled(run.id);
    expect(run.status).toBe("failed");
    expect(run.stopReason).toBe("validationFailedAfterFinalIteration");
    expect(calls).toBe(3);
    expect(run.iterations.map((i) => i.validationPassed)).toEqual([false, false, false]);
  });

  it("fails immediately with no validation command (native validationUnavailable)", async () => {
    const engine = new LoopEngine({ executeAgent: async () => "out" });
    const run = engine.start(makeLoop({ validationCommand: "", maxIterations: 4 }), cwd());
    await engine.settled(run.id);
    expect(run.status).toBe("failed");
    expect(run.stopReason).toBe("validationUnavailable");
    expect(run.iterations).toHaveLength(1);
  });

  it("fails when the agent throws (agentFailed), recording the error", async () => {
    const engine = new LoopEngine({
      executeAgent: async () => {
        throw new Error("agent exploded");
      },
    });
    const run = engine.start(makeLoop(), cwd());
    await engine.settled(run.id);
    expect(run.status).toBe("failed");
    expect(run.stopReason).toBe("agentFailed");
    expect(run.iterations[0]).toMatchObject({ output: "agent exploded", validationPassed: null });
  });

  it("a throwing validation runner is treated as a failure, never stuck as running", async () => {
    const engine = new LoopEngine({
      executeAgent: async () => "out",
      runValidation: async () => {
        throw new Error("validation runner blew up");
      },
    });
    const run = engine.start(makeLoop({ validationCommand: "whatever", maxIterations: 2 }), cwd());
    await engine.settled(run.id);
    // Both iterations ran (validation never "passed"), and the run reached a
    // terminal state instead of hanging on "running".
    expect(run.status).toBe("failed");
    expect(run.stopReason).toBe("validationFailedAfterFinalIteration");
    expect(run.iterations.map((i) => i.validationPassed)).toEqual([false, false]);
  });

  it("stops cooperatively when stop() is called mid-iteration (userStopped)", async () => {
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    let calls = 0;
    const engine = new LoopEngine({
      executeAgent: async () => {
        calls += 1;
        await gate;
        return "out";
      },
      runValidation: async () => false,
    });
    const run = engine.start(makeLoop({ maxIterations: 5 }), cwd());
    // The first agent call is in flight; ask to stop, then let it finish.
    engine.stop(run.id);
    release();
    await engine.settled(run.id);
    expect(run.status).toBe("stopped");
    expect(run.stopReason).toBe("userStopped");
    expect(calls).toBe(1); // never started a second iteration
  });
});
