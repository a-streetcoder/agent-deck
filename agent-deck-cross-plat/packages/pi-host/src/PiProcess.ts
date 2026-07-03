import { EventEmitter } from "node:events";
import type { ChildProcess } from "node:child_process";
import spawn from "cross-spawn";
import { createJsonlReader, type JsonlReader } from "./jsonl.ts";

const STDERR_CAP_BYTES = 64 * 1024;
const KILL_GRACE_MS = 3_000;

export interface PiProcessOptions {
  binPath: string;
  args: string[];
  cwd: string;
  env?: Record<string, string | undefined>;
}

export interface PiProcessExit {
  code: number | null;
  signal: NodeJS.Signals | null;
}

export interface PiProcessEvents {
  line: [string];
  exit: [PiProcessExit];
}

/**
 * A single `pi --mode rpc` subprocess: spawn, LF-only line events from stdout,
 * capped stderr capture, graceful stop (SIGTERM, then SIGKILL after a grace period).
 */
export class PiProcess extends EventEmitter<PiProcessEvents> {
  private child: ChildProcess | null = null;
  private reader: JsonlReader | null = null;
  private stderrBuf = "";
  private exited: PiProcessExit | null = null;

  constructor(private readonly options: PiProcessOptions) {
    super();
  }

  start(): void {
    if (this.child) throw new Error("PiProcess already started");
    const child = spawn(this.options.binPath, this.options.args, {
      cwd: this.options.cwd,
      env: { ...process.env, ...this.options.env },
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child = child;

    this.reader = createJsonlReader((line) => this.emit("line", line));
    child.stdout?.on("data", (chunk: Buffer) => this.reader?.push(chunk));
    child.stdout?.on("end", () => this.reader?.end());

    child.stderr?.on("data", (chunk: Buffer) => {
      this.stderrBuf = (this.stderrBuf + chunk.toString("utf8")).slice(-STDERR_CAP_BYTES);
    });

    child.on("error", (error) => {
      // Spawn failures (ENOENT etc.) surface as an exit with the message in stderr.
      this.stderrBuf = (this.stderrBuf + String(error)).slice(-STDERR_CAP_BYTES);
      if (!this.exited) {
        this.exited = { code: null, signal: null };
        this.emit("exit", this.exited);
      }
    });

    child.on("exit", (code, signal) => {
      if (!this.exited) {
        this.exited = { code, signal };
        this.emit("exit", this.exited);
      }
    });
  }

  get isRunning(): boolean {
    return this.child !== null && this.exited === null;
  }

  get stderr(): string {
    return this.stderrBuf;
  }

  writeLine(line: string): void {
    if (!this.child || this.exited) {
      throw new Error("PiProcess is not running");
    }
    this.child.stdin?.write(line);
  }

  async stop(): Promise<PiProcessExit> {
    const child = this.child;
    if (!child || this.exited) {
      return this.exited ?? { code: null, signal: null };
    }
    return await new Promise<PiProcessExit>((resolve) => {
      const killTimer = setTimeout(() => child.kill("SIGKILL"), KILL_GRACE_MS);
      killTimer.unref();
      this.once("exit", (exit) => {
        clearTimeout(killTimer);
        resolve(exit);
      });
      child.kill("SIGTERM");
    });
  }
}
