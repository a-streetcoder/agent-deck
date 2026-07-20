import { Effect, Either, Exit, Option, Scope } from "effect";
import { describe, expect, it } from "vitest";
import { makeServerRuntime } from "../src/runtime.ts";
import {
  defaultShellCandidates,
  nodePtyAdapter,
  spawnTerminal,
  TerminalHost,
  type PtyAdapter,
  type PtyProcessLike,
  type PtySpawnInput,
  type TerminalEvent,
  type TerminalExit,
} from "../src/services/terminal.ts";

/**
 * TerminalHost service unit tests against a scripted fake PTY adapter (the
 * donor's PtyAdapter seam), following the piHost.test.ts conventions —
 * lifecycle edge cases: scope-close kill, exit dispatch, scrollback replay on
 * reattach, resize, shell-candidate fallback — plus one real node-pty smoke
 * test (echo roundtrip + scope-close kill verified by kill(pid,0) polling).
 */

class FakePty implements PtyProcessLike {
  readonly pid = 4242;
  readonly writes: string[] = [];
  readonly resizes: Array<{ cols: number; rows: number }> = [];
  readonly kills: Array<string | undefined> = [];
  pauses = 0;
  resumes = 0;
  /** When set, kill() immediately emits this exit (a well-behaved shell). */
  exitOnKill: TerminalExit | null = { exitCode: 0, signal: null };
  private dataCallback: ((data: string) => void) | null = null;
  private exitCallback: ((event: TerminalExit) => void) | null = null;

  write(data: string): void {
    this.writes.push(data);
  }
  resize(cols: number, rows: number): void {
    this.resizes.push({ cols, rows });
  }
  kill(signal?: string): void {
    this.kills.push(signal);
    if (this.exitOnKill) this.emitExit(this.exitOnKill);
  }
  pause(): void {
    this.pauses += 1;
  }
  resume(): void {
    this.resumes += 1;
  }
  onData(callback: (data: string) => void): () => void {
    this.dataCallback = callback;
    return () => {
      this.dataCallback = null;
    };
  }
  onExit(callback: (event: TerminalExit) => void): () => void {
    this.exitCallback = callback;
    return () => {
      this.exitCallback = null;
    };
  }
  emitData(data: string): void {
    this.dataCallback?.(data);
  }
  emitExit(event: TerminalExit): void {
    this.exitCallback?.(event);
  }
}

function fakeAdapter(): { adapter: PtyAdapter; spawns: PtySpawnInput[]; ptys: FakePty[] } {
  const spawns: PtySpawnInput[] = [];
  const ptys: FakePty[] = [];
  return {
    adapter: {
      spawn: (input) => {
        spawns.push(input);
        const pty = new FakePty();
        ptys.push(pty);
        return pty;
      },
    },
    spawns,
    ptys,
  };
}

const spawnOpts = { cwd: process.cwd(), shellCandidates: [{ shell: "fake-shell" }] };

function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function expectProcessGone(pid: number): Promise<void> {
  const deadline = Date.now() + 5_000;
  while (processAlive(pid) && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  expect(processAlive(pid)).toBe(false);
}

describe("TerminalHost scoped PTY service (fake adapter)", () => {
  it("open → input → output roundtrip, and output reaches attached listeners", async () => {
    const { adapter, spawns, ptys } = fakeAdapter();
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const handle = yield* spawnTerminal(adapter, { ...spawnOpts, cols: 100, rows: 40 });
          expect(handle.pid).toBe(4242);
          expect(handle.shell).toBe("fake-shell");
          expect(spawns[0]).toMatchObject({ shell: "fake-shell", cols: 100, rows: 40 });

          const events: TerminalEvent[] = [];
          yield* handle.attach((event) => events.push(event));

          yield* handle.write("echo hi\r");
          expect(ptys[0]!.writes).toEqual(["echo hi\r"]);

          ptys[0]!.emitData("hi\r\n");
          expect(events).toEqual([{ _tag: "Output", data: "hi\r\n" }]);
        }),
      ),
    );
  });

  it("scrollback is replayed to a late attacher, atomically with subscription", async () => {
    const { adapter, ptys } = fakeAdapter();
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const handle = yield* spawnTerminal(adapter, spawnOpts);
          ptys[0]!.emitData("first ");
          ptys[0]!.emitData("second");

          // Late attach: buffer replayed in the attachment, not as events.
          const events: TerminalEvent[] = [];
          const attachment = yield* handle.attach((event) => events.push(event));
          expect(attachment.scrollback).toBe("first second");
          expect(attachment.running).toBe(true);
          expect(events).toEqual([]);

          // Later output flows as events only (never duplicated into the past).
          ptys[0]!.emitData("third");
          expect(events).toEqual([{ _tag: "Output", data: "third" }]);

          // Detached listener stops receiving; a re-attach sees the new buffer.
          attachment.unsubscribe();
          ptys[0]!.emitData("fourth");
          expect(events).toHaveLength(1);
          const reattached = yield* handle.attach(() => {});
          expect(reattached.scrollback).toBe("first secondthirdfourth");
        }),
      ),
    );
  });

  it("scrollback is capped by characters, trimming the oldest output", async () => {
    const { adapter, ptys } = fakeAdapter();
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const handle = yield* spawnTerminal(adapter, { ...spawnOpts, maxScrollbackChars: 8 });
          ptys[0]!.emitData("0123456789");
          ptys[0]!.emitData("AB");
          const attachment = yield* handle.attach(() => {});
          expect(attachment.scrollback).toBe("456789AB");
        }),
      ),
    );
  });

  it("scrollback strips terminal query/report sequences; live events stay raw", async () => {
    const ESC = String.fromCharCode(0x1b);
    const BEL = String.fromCharCode(0x07);
    const { adapter, ptys } = fakeAdapter();
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const handle = yield* spawnTerminal(adapter, spawnOpts);
          const events: TerminalEvent[] = [];
          yield* handle.attach((event) => events.push(event));

          // ConPTY-style startup DSR query + an OSC 11 color query, mixed with
          // ordinary text and an SGR sequence that must SURVIVE.
          const raw = `a${ESC}[6nb${ESC}]11;?${BEL}c${ESC}[31md`;
          ptys[0]!.emitData(raw);
          // Live listeners saw the untouched bytes (a live xterm must answer).
          expect(events).toEqual([{ _tag: "Output", data: raw }]);
          // Scrollback replay is sanitized: queries gone, SGR kept.
          const attachment = yield* handle.attach(() => {});
          expect(attachment.scrollback).toBe(`abc${ESC}[31md`);
        }),
      ),
    );
  });

  it("a query sequence split across PTY chunks is still stripped from scrollback", async () => {
    const ESC = String.fromCharCode(0x1b);
    const { adapter, ptys } = fakeAdapter();
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const handle = yield* spawnTerminal(adapter, spawnOpts);
          // CPR reply (what a terminal answers to CSI 6n) split mid-sequence.
          ptys[0]!.emitData(`x${ESC}[24`);
          ptys[0]!.emitData(";1Ry");
          const attachment = yield* handle.attach(() => {});
          expect(attachment.scrollback).toBe("xy");
        }),
      ),
    );
  });

  it("pause/resume reach the PTY while running and no-op after exit", async () => {
    const { adapter, ptys } = fakeAdapter();
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const handle = yield* spawnTerminal(adapter, spawnOpts);
          yield* handle.pause;
          yield* handle.resume;
          expect(ptys[0]!.pauses).toBe(1);
          expect(ptys[0]!.resumes).toBe(1);

          ptys[0]!.emitExit({ exitCode: 0, signal: null });
          yield* handle.pause;
          yield* handle.resume;
          expect(ptys[0]!.pauses).toBe(1);
          expect(ptys[0]!.resumes).toBe(1);
        }),
      ),
    );
  });

  it("resize is applied to the PTY and fails typed after exit", async () => {
    const { adapter, ptys } = fakeAdapter();
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const handle = yield* spawnTerminal(adapter, spawnOpts);
          yield* handle.resize(80, 24);
          expect(ptys[0]!.resizes).toEqual([{ cols: 80, rows: 24 }]);

          ptys[0]!.emitExit({ exitCode: 0, signal: null });
          const late = yield* Effect.either(handle.resize(120, 30));
          expect(Either.isLeft(late)).toBe(true);
          if (Either.isLeft(late)) expect(late.left._tag).toBe("TerminalExited");
          expect(ptys[0]!.resizes).toHaveLength(1);
        }),
      ),
    );
  });

  it("PTY exit dispatches an Exit event, settles awaitExit, and fails writes", async () => {
    const { adapter, ptys } = fakeAdapter();
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const handle = yield* spawnTerminal(adapter, spawnOpts);
          const events: TerminalEvent[] = [];
          yield* handle.attach((event) => events.push(event));

          ptys[0]!.emitExit({ exitCode: 3, signal: null });
          expect(events).toEqual([{ _tag: "Exit", exit: { exitCode: 3, signal: null } }]);
          expect(yield* handle.isRunning).toBe(false);
          expect(yield* handle.awaitExit).toEqual({ exitCode: 3, signal: null });
          expect(Option.getOrThrow(yield* handle.exit)).toEqual({ exitCode: 3, signal: null });

          const write = yield* Effect.either(handle.write("x"));
          expect(Either.isLeft(write)).toBe(true);
          if (Either.isLeft(write)) expect(write.left._tag).toBe("TerminalExited");

          // Attach after exit: scrollback replay + running:false (reattach
          // to an exited terminal still shows its final output).
          const attachment = yield* handle.attach(() => {});
          expect(attachment.running).toBe(false);
        }),
      ),
    );
  });

  it("scope close kills the PTY (release escalation) exactly once", async () => {
    const { adapter, ptys } = fakeAdapter();
    await Effect.runPromise(
      Effect.gen(function* () {
        const scope = yield* Scope.make();
        const handle = yield* Scope.extend(spawnTerminal(adapter, spawnOpts), scope);
        expect(yield* handle.isRunning).toBe(true);

        yield* Scope.close(scope, Exit.void);
        expect(ptys[0]!.kills).toEqual(["SIGTERM"]);
        expect(yield* handle.isRunning).toBe(false);
      }),
    );
  });

  it("release escalates to SIGKILL when the shell ignores the first kill", async () => {
    const { adapter, ptys } = fakeAdapter();
    await Effect.runPromise(
      Effect.gen(function* () {
        const scope = yield* Scope.make();
        const handle = yield* Scope.extend(spawnTerminal(adapter, spawnOpts), scope);
        const pty = ptys[0]!;
        pty.exitOnKill = null; // ignore SIGTERM
        const closing = yield* Effect.fork(Scope.close(scope, Exit.void));
        // First kill lands immediately; the SIGKILL follows after the grace.
        yield* Effect.sleep("50 millis");
        expect(pty.kills).toEqual(["SIGTERM"]);
        yield* Effect.sleep("1100 millis");
        expect(pty.kills).toEqual(["SIGTERM", "SIGKILL"]);
        pty.emitExit({ exitCode: null, signal: 9 });
        yield* Effect.fromFiber(closing);
        expect(yield* handle.awaitExit).toEqual({ exitCode: null, signal: 9 });
      }),
    );
  }, 10_000);

  it("release is a no-op when the PTY already exited", async () => {
    const { adapter, ptys } = fakeAdapter();
    await Effect.runPromise(
      Effect.gen(function* () {
        const scope = yield* Scope.make();
        yield* Scope.extend(spawnTerminal(adapter, spawnOpts), scope);
        ptys[0]!.emitExit({ exitCode: 0, signal: null });
        yield* Scope.close(scope, Exit.void);
        expect(ptys[0]!.kills).toEqual([]);
      }),
    );
  });

  it("falls through the shell candidate chain and fails typed when all refuse", async () => {
    const failing = new Set(["bad-1", "bad-2"]);
    const spawns: string[] = [];
    const adapter: PtyAdapter = {
      spawn: (input) => {
        spawns.push(input.shell);
        if (failing.has(input.shell)) throw new Error(`ENOENT: ${input.shell}`);
        return new FakePty();
      },
    };

    // Second candidate wins after the first throws.
    const handle = await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const h = yield* spawnTerminal(adapter, {
            cwd: process.cwd(),
            shellCandidates: [{ shell: "bad-1" }, { shell: "good" }],
          });
          return { shell: h.shell };
        }),
      ),
    );
    expect(handle.shell).toBe("good");
    expect(spawns).toEqual(["bad-1", "good"]);

    // Every candidate failing surfaces TerminalSpawnFailed with the chain.
    const result = await Effect.runPromise(
      Effect.scoped(
        Effect.either(
          spawnTerminal(adapter, {
            cwd: process.cwd(),
            shellCandidates: [{ shell: "bad-1" }, { shell: "bad-2" }],
          }),
        ),
      ),
    );
    expect(Either.isLeft(result)).toBe(true);
    if (Either.isLeft(result)) {
      expect(result.left._tag).toBe("TerminalSpawnFailed");
      expect(result.left.attempted).toEqual(["bad-1", "bad-2"]);
    }
  });

  it("blocklisted env keys never reach the spawn env", async () => {
    const { adapter, spawns } = fakeAdapter();
    await Effect.runPromise(
      Effect.scoped(
        spawnTerminal(adapter, {
          ...spawnOpts,
          env: { KEEP: "yes", PORT: "3000", ELECTRON_RUN_AS_NODE: "1", GONE: undefined },
        }),
      ),
    );
    expect(spawns[0]!.env).toEqual({ KEEP: "yes" });
  });

  it("oversized PTY reads are split into wire-bounded output chunks", async () => {
    const { adapter, ptys } = fakeAdapter();
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const handle = yield* spawnTerminal(adapter, spawnOpts);
          const chunks: number[] = [];
          yield* handle.attach((event) => {
            if (event._tag === "Output") chunks.push(event.data.length);
          });
          ptys[0]!.emitData("x".repeat(65_536 + 10));
          expect(chunks).toEqual([65_536, 10]);
        }),
      ),
    );
  });
});

describe("defaultShellCandidates", () => {
  it("win32: pwsh → Windows PowerShell → ComSpec/cmd (donor order)", () => {
    const candidates = defaultShellCandidates("win32", {
      SystemRoot: "C:\\Windows",
      ComSpec: "C:\\Windows\\System32\\cmd.exe",
    });
    expect(candidates.map((c) => c.shell)).toEqual([
      "pwsh.exe",
      "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
      "powershell.exe",
      "C:\\Windows\\System32\\cmd.exe",
      "cmd.exe",
    ]);
    expect(candidates[0]!.args).toEqual(["-NoLogo"]);
  });

  it("posix: $SHELL first, then zsh/bash/sh fallbacks, deduplicated", () => {
    const candidates = defaultShellCandidates("linux", { SHELL: "/bin/bash" });
    expect(candidates.map((c) => c.shell)).toEqual([
      "/bin/bash",
      "/bin/zsh",
      "/bin/sh",
      "bash",
      "sh",
    ]);
  });

  it("AGENT_DECK_TERMINAL_SHELL overrides as the first candidate (test seam)", () => {
    const candidates = defaultShellCandidates("win32", {
      AGENT_DECK_TERMINAL_SHELL: "C:\\Windows\\System32\\cmd.exe",
      SystemRoot: "C:\\Windows",
      ComSpec: "C:\\Windows\\System32\\cmd.exe",
    });
    expect(candidates[0]).toEqual({ shell: "C:\\Windows\\System32\\cmd.exe" });
    // The override deduplicates against the platform chain (ComSpec here) and
    // the remaining fallbacks still follow.
    expect(candidates.map((c) => c.shell)).toEqual([
      "C:\\Windows\\System32\\cmd.exe",
      "pwsh.exe",
      "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
      "powershell.exe",
      "cmd.exe",
    ]);
  });
});

// macOS CI: node-pty's darwin prebuild ships spawn-helper without exec
// permission (known packaging issue), so every shell candidate fails to
// spawn on the runner. macOS is not a ship target (focus: linux + windows,
// both green in CI); revisit with a chmod+x postinstall if mac ever is.
// Local mac dev runs still exercise this (the skip is CI-scoped).
describe.skipIf(process.platform === "darwin" && !!process.env.CI)(
  "TerminalHost real node-pty smoke test",
  () => {
    it("spawns a real shell through the runtime, echoes input, and scope close kills it", async () => {
      const runtime = makeServerRuntime();
      try {
        const scope = runtime.runSync(Scope.make());
        const { pid, sawEcho } = await runtime.runPromise(
          Effect.gen(function* () {
            const host = yield* TerminalHost;
            const handle = yield* Scope.extend(host.spawn({ cwd: process.cwd() }), scope);
            expect(handle.pid).toBeGreaterThan(0);

            let output = "";
            yield* handle.attach((event) => {
              if (event._tag === "Output") output += event.data;
            });

            // Echo roundtrip: the token comes back through the PTY (both as the
            // echoed keystrokes and the command output — either proves the loop).
            yield* handle.write("echo agent-deck-pty-smoke\r");
            yield* Effect.promise(async () => {
              const deadline = Date.now() + 10_000;
              while (!output.includes("agent-deck-pty-smoke") && Date.now() < deadline) {
                await new Promise((resolve) => setTimeout(resolve, 50));
              }
            });
            return { pid: handle.pid, sawEcho: output.includes("agent-deck-pty-smoke") };
          }),
        );
        expect(sawEcho).toBe(true);
        expect(processAlive(pid)).toBe(true);

        // Scope close kills the real PTY — verified by kill(pid, 0) polling.
        await runtime.runPromise(Scope.close(scope, Exit.void));
        await expectProcessGone(pid);
      } finally {
        await runtime.dispose();
      }
    }, 30_000);

    // win32-gated: ConPTY reports a missing executable synchronously ("File not
    // found"), which is what the candidate chain relies on; POSIX forkpty may
    // defer the failure into the child.
    it.runIf(process.platform === "win32")(
      "nodePtyAdapter spawn failure throws (candidate-chain contract)",
      () => {
        expect(() =>
          nodePtyAdapter.spawn({
            shell: "definitely-not-a-real-shell-xyz.exe",
            args: [],
            cwd: process.cwd(),
            cols: 80,
            rows: 24,
            env: {},
          }),
        ).toThrow();
      },
    );
  },
);
