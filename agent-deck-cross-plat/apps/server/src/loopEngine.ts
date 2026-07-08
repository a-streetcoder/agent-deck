import { exec } from "node:child_process";
import { randomUUID } from "node:crypto";
import { promisify } from "node:util";
import {
  clampMaxIterations,
  isLoopRunTerminal,
  type LoopDefinition,
  type LoopRun,
  type LoopRunStatus,
  type LoopStopReason,
} from "@agent-deck/domain";

/**
 * Loop run engine (native PiAgentSessionStore.launchSingleAgentLoop), minimal
 * single-agent form: a fixed-count for-loop that drives the loop's agent to
 * completion each iteration, runs the validation command, and stops early on
 * exit 0 (success) — otherwise continues to maxIterations. The agent executor is
 * injected so the control flow is hermetically unit-testable without pi; the
 * server wires it to SessionManager.runSubagent. This slice is the engine core +
 * run state; the REST/WS surface + live UI are the next slice.
 */

const execAsync = promisify(exec);

/** Run a validation command in cwd through the platform shell; true = exit 0. */
export async function runValidationCommand(cwd: string, command: string): Promise<boolean> {
  try {
    await execAsync(command, { cwd, timeout: 120_000, maxBuffer: 8_000_000, windowsHide: true });
    return true;
  } catch {
    // Non-zero exit (or a spawn error) counts as a failed validation.
    return false;
  }
}

export interface LoopEngineDeps {
  /** Drive the loop's agent on its goal to completion; returns its output. Throws on failure. */
  executeAgent: (loop: LoopDefinition, cwd: string, projectId?: string) => Promise<string>;
  /** Run the validation command in cwd; true = passed (exit 0). Defaults to the real shell. */
  runValidation?: (cwd: string, command: string) => Promise<boolean>;
  /** Injectable clock (defaults to the wall clock). */
  now?: () => string;
}

export class LoopEngine {
  private readonly runs = new Map<string, LoopRun>();
  private readonly settledPromises = new Map<string, Promise<void>>();
  private readonly executeAgent: LoopEngineDeps["executeAgent"];
  private readonly runValidation: (cwd: string, command: string) => Promise<boolean>;
  private readonly now: () => string;

  constructor(deps: LoopEngineDeps) {
    this.executeAgent = deps.executeAgent;
    this.runValidation = deps.runValidation ?? runValidationCommand;
    this.now = deps.now ?? (() => new Date().toISOString());
  }

  get(id: string): LoopRun | undefined {
    return this.runs.get(id);
  }

  list(): LoopRun[] {
    return [...this.runs.values()];
  }

  /** Resolves once the run reaches a terminal state (for tests + await-on-finish). */
  settled(id: string): Promise<void> {
    return this.settledPromises.get(id) ?? Promise.resolve();
  }

  /** Ask a running loop to stop after the current iteration (cooperative). */
  stop(id: string): void {
    const run = this.runs.get(id);
    if (run && run.status === "running") run.status = "stopping";
  }

  /** Start a run (executes in the background); returns the initial run record. */
  start(loop: LoopDefinition, cwd: string, projectId?: string): LoopRun {
    const run: LoopRun = {
      id: randomUUID(),
      loopName: loop.name,
      projectId,
      status: "running",
      currentIteration: 0,
      maxIterations: clampMaxIterations(loop.maxIterations),
      iterations: [],
      startedAt: this.now(),
    };
    this.runs.set(run.id, run);
    this.settledPromises.set(run.id, this.execute(run, loop, cwd, projectId));
    return run;
  }

  // A method (not an inline `run.status === "stopping"`) so TS doesn't narrow the
  // property across the await — stop() mutates run.status from another task.
  private stopRequested(run: LoopRun): boolean {
    return run.status === "stopping";
  }

  private finalize(run: LoopRun, status: LoopRunStatus, reason: LoopStopReason): void {
    run.status = status;
    run.stopReason = reason;
    run.endedAt = this.now();
  }

  private async execute(
    run: LoopRun,
    loop: LoopDefinition,
    cwd: string,
    projectId?: string,
  ): Promise<void> {
    // Outer guard: this runs fire-and-forget (its promise is only awaited by
    // tests), so ANY unexpected throw must still finalize the run — otherwise it
    // sticks at "running" forever and the promise rejects unhandled.
    try {
      for (let index = 1; index <= run.maxIterations; index += 1) {
        if (this.stopRequested(run)) {
          this.finalize(run, "stopped", "userStopped");
          return;
        }
        run.currentIteration = index;

        let output: string;
        try {
          output = await this.executeAgent(loop, cwd, projectId);
        } catch (error) {
          run.iterations.push({
            index,
            output: error instanceof Error ? error.message : String(error),
            validationPassed: null,
          });
          this.finalize(run, "failed", "agentFailed");
          return;
        }

        // A stop requested while the agent ran takes effect before validation
        // (native rechecks the persisted run after the child returns).
        if (this.stopRequested(run)) {
          run.iterations.push({ index, output, validationPassed: null });
          this.finalize(run, "stopped", "userStopped");
          return;
        }

        // No validation command = no success condition; native ends the run.
        if (!loop.validationCommand) {
          run.iterations.push({ index, output, validationPassed: null });
          this.finalize(run, "failed", "validationUnavailable");
          return;
        }

        // A validation runner that throws (a custom injected one; the default
        // never does) counts as a failed validation, like a non-zero exit.
        let passed: boolean;
        try {
          passed = await this.runValidation(cwd, loop.validationCommand);
        } catch {
          passed = false;
        }
        run.iterations.push({ index, output, validationPassed: passed });
        if (passed) {
          this.finalize(run, "completed", "success");
          return;
        }
      }
      // Ran every iteration without the validation passing.
      this.finalize(run, "failed", "validationFailedAfterFinalIteration");
    } catch {
      // Defensive backstop — never leave a run stuck as "running".
      if (!isLoopRunTerminal(run.status)) this.finalize(run, "failed", "agentFailed");
    }
  }
}
