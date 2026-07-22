import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Effect, Either, Exit, Scope } from "effect";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { makeServerRuntime } from "../src/runtime.ts";
import {
  extractLoopbackPorts,
  listProjectScripts,
  resolveScriptCommand,
  ScriptRunner,
  spawnScript,
  type PortProber,
  type ScriptAdapter,
  type ScriptEvent,
  type ScriptExit,
  type ScriptProcessLike,
  type ScriptSpawnInput,
} from "../src/services/scriptRunner.ts";

/**
 * ScriptRunner service unit tests against a scripted fake child-process adapter
 * (the terminal.ts PtyAdapter seam, for a plain child), following the
 * terminal.test.ts conventions — declared-script listing/resolution, loopback
 * port extraction, output streaming + port detection + confirm probe, scope-close
 * tree-kill — plus one real child-process smoke test against a scratch project
 * (a node one-liner that prints a listening URL then serves; stop kills it,
 * verified by kill(pid,0) polling).
 */

// --- Scripted fake adapter -------------------------------------------------

class FakeScript implements ScriptProcessLike {
  readonly pid = 4321;
  readonly kills: Array<"SIGTERM" | "SIGKILL"> = [];
  /** When set, kill() immediately emits this exit (a well-behaved child). */
  exitOnKill: ScriptExit | null = { exitCode: 0, signal: "SIGTERM" };
  private dataCallback: ((data: string) => void) | null = null;
  private exitCallback: ((event: ScriptExit) => void) | null = null;

  kill(signal: "SIGTERM" | "SIGKILL"): void {
    this.kills.push(signal);
    if (this.exitOnKill) this.emitExit(this.exitOnKill);
  }
  onData(callback: (data: string) => void): () => void {
    this.dataCallback = callback;
    return () => {
      this.dataCallback = null;
    };
  }
  onExit(callback: (event: ScriptExit) => void): () => void {
    this.exitCallback = callback;
    return () => {
      this.exitCallback = null;
    };
  }
  emitData(data: string): void {
    this.dataCallback?.(data);
  }
  emitExit(event: ScriptExit): void {
    this.exitCallback?.(event);
  }
}

function fakeAdapter(): {
  adapter: ScriptAdapter;
  spawns: ScriptSpawnInput[];
  procs: FakeScript[];
} {
  const spawns: ScriptSpawnInput[] = [];
  const procs: FakeScript[] = [];
  return {
    adapter: {
      spawn: (input) => {
        spawns.push(input);
        const proc = new FakeScript();
        procs.push(proc);
        return proc;
      },
    },
    spawns,
    procs,
  };
}

/** Base spawn options: a command override (bypasses package.json) + always-true probe. */
const okProbe: PortProber = async () => true;
const baseOpts = { scriptName: "dev", cwd: process.cwd(), command: "noop", probePort: okProbe };

// Let the microtask that the confirm probe schedules run.
const flush = async (): Promise<void> => {
  await new Promise((resolve) => setTimeout(resolve, 0));
};

function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function expectProcessGone(pid: number): Promise<void> {
  const deadline = Date.now() + 8_000;
  while (processAlive(pid) && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  expect(processAlive(pid)).toBe(false);
}

// --- Pure helpers ----------------------------------------------------------

describe("extractLoopbackPorts", () => {
  it("extracts loopback dev-server ports, ignoring non-loopback hosts", () => {
    expect(extractLoopbackPorts("Local: http://localhost:5173/")).toEqual([5173]);
    expect(extractLoopbackPorts("http://127.0.0.1:3000")).toEqual([3000]);
    expect(extractLoopbackPorts("bound http://0.0.0.0:8080 all ifaces")).toEqual([8080]);
    expect(extractLoopbackPorts("ipv6 http://[::1]:4321/")).toEqual([4321]);
    // A LAN IP / a domain is never a candidate.
    expect(extractLoopbackPorts("Network: http://192.168.1.5:3000/")).toEqual([]);
    expect(extractLoopbackPorts("prod https://example.com:443/")).toEqual([]);
    // A URL with no port is skipped (a dev server always advertises one).
    expect(extractLoopbackPorts("http://localhost/")).toEqual([]);
  });

  it("reports the Local URL from a mixed Vite-style banner, distinct ports in order", () => {
    const banner = [
      "  ➜  Local:   http://localhost:5173/",
      "  ➜  Network: http://192.168.1.5:5173/",
      "  ➜  Alt:     http://127.0.0.1:5174/",
    ].join("\n");
    expect(extractLoopbackPorts(banner)).toEqual([5173, 5174]);
  });
});

describe("listProjectScripts / resolveScriptCommand", () => {
  let dir: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "agent-deck-scripts-"));
  });
  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it("lists declared package.json scripts and resolves a command by name", () => {
    writeFileSync(
      join(dir, "package.json"),
      JSON.stringify({ scripts: { dev: "vite", build: "vite build", bad: 42 } }),
    );
    expect(listProjectScripts(dir)).toEqual([
      { name: "dev", command: "vite" },
      { name: "build", command: "vite build" },
    ]);
    expect(resolveScriptCommand(dir, "dev")).toBe("vite");
    // A non-string script value is dropped; an undeclared name resolves to null.
    expect(resolveScriptCommand(dir, "bad")).toBeNull();
    expect(resolveScriptCommand(dir, "nope")).toBeNull();
  });

  it("returns an empty list for a missing / invalid / scriptless package.json", () => {
    expect(listProjectScripts(dir)).toEqual([]); // no package.json
    writeFileSync(join(dir, "package.json"), "{ not json");
    expect(listProjectScripts(dir)).toEqual([]);
    writeFileSync(join(dir, "package.json"), JSON.stringify({ name: "x" }));
    expect(listProjectScripts(dir)).toEqual([]);
  });
});

// --- Scoped spawn (fake adapter) -------------------------------------------

describe("spawnScript scoped child service (fake adapter)", () => {
  it("streams output to attached listeners and buffers scrollback", async () => {
    const { adapter, procs, spawns } = fakeAdapter();
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const handle = yield* spawnScript(adapter, baseOpts);
          expect(handle.pid).toBe(4321);
          expect(handle.scriptName).toBe("dev");
          expect(spawns[0]).toMatchObject({ command: "noop", cwd: process.cwd() });

          const events: ScriptEvent[] = [];
          yield* handle.attach((event) => events.push(event));
          procs[0]!.emitData("hello\n");
          expect(events).toEqual([{ _tag: "Output", data: "hello\n" }]);

          // Late attach replays the scrollback, not as events.
          const attachment = yield* handle.attach(() => {});
          expect(attachment.scrollback).toBe("hello\n");
          expect(attachment.running).toBe(true);
          expect(attachment.server).toBeNull();
        }),
      ),
    );
  });

  it("detects the dev-server port from stdout and confirms it via the probe", async () => {
    const probed: number[] = [];
    const probePort: PortProber = async (port) => {
      probed.push(port);
      return port === 5173;
    };
    const { adapter, procs } = fakeAdapter();
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const handle = yield* spawnScript(adapter, { ...baseOpts, probePort });
          const events: ScriptEvent[] = [];
          yield* handle.attach((event) => events.push(event));
          procs[0]!.emitData("  ➜  Local: http://localhost:5173/\n");
          yield* Effect.promise(flush);

          const serverEvents = events.filter((e) => e._tag === "Server");
          expect(serverEvents).toEqual([
            {
              _tag: "Server",
              server: { host: "localhost", port: 5173, url: "http://localhost:5173" },
            },
          ]);
          expect(probed).toEqual([5173]);
          // The current server rides a later attach so a reconnect can re-embed.
          const attachment = yield* handle.attach(() => {});
          expect(attachment.server).toEqual({
            host: "localhost",
            port: 5173,
            url: "http://localhost:5173",
          });
        }),
      ),
    );
  });

  it("detects a URL split across two reads (carryover tail)", async () => {
    const { adapter, procs } = fakeAdapter();
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const handle = yield* spawnScript(adapter, baseOpts);
          const events: ScriptEvent[] = [];
          yield* handle.attach((event) => events.push(event));
          procs[0]!.emitData("serving on http://localh");
          procs[0]!.emitData("ost:4173/ now");
          yield* Effect.promise(flush);
          expect(events.filter((e) => e._tag === "Server")).toEqual([
            {
              _tag: "Server",
              server: { host: "localhost", port: 4173, url: "http://localhost:4173" },
            },
          ]);
        }),
      ),
    );
  });

  it("does not report a server when the confirm probe fails", async () => {
    const probePort: PortProber = async () => false;
    const { adapter, procs } = fakeAdapter();
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const handle = yield* spawnScript(adapter, { ...baseOpts, probePort });
          const events: ScriptEvent[] = [];
          yield* handle.attach((event) => events.push(event));
          procs[0]!.emitData("http://localhost:9999/\n");
          yield* Effect.promise(flush);
          expect(events.filter((e) => e._tag === "Server")).toEqual([]);
        }),
      ),
    );
  });

  it("never reports a non-loopback origin printed by the script", async () => {
    let probes = 0;
    const probePort: PortProber = async () => {
      probes += 1;
      return true;
    };
    const { adapter, procs } = fakeAdapter();
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const handle = yield* spawnScript(adapter, { ...baseOpts, probePort });
          const events: ScriptEvent[] = [];
          yield* handle.attach((event) => events.push(event));
          procs[0]!.emitData("open http://evil.example.com:3000/ and http://10.0.0.9:3000/\n");
          yield* Effect.promise(flush);
          expect(events.filter((e) => e._tag === "Server")).toEqual([]);
          expect(probes).toBe(0); // a non-loopback host is never even probed
        }),
      ),
    );
  });

  it("exit dispatches an Exit event, settles awaitExit, and marks not running", async () => {
    const { adapter, procs } = fakeAdapter();
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const handle = yield* spawnScript(adapter, baseOpts);
          const events: ScriptEvent[] = [];
          yield* handle.attach((event) => events.push(event));
          procs[0]!.emitExit({ exitCode: 1, signal: null });
          expect(events).toEqual([{ _tag: "Exit", exit: { exitCode: 1, signal: null } }]);
          expect(yield* handle.isRunning).toBe(false);
          expect(yield* handle.awaitExit).toEqual({ exitCode: 1, signal: null });

          const attachment = yield* handle.attach(() => {});
          expect(attachment.running).toBe(false);
        }),
      ),
    );
  });

  it("fails typed with ScriptNotDeclared when the name has no command", async () => {
    const dir = mkdtempSync(join(tmpdir(), "agent-deck-scripts-"));
    try {
      writeFileSync(join(dir, "package.json"), JSON.stringify({ scripts: { dev: "vite" } }));
      const { adapter, spawns } = fakeAdapter();
      const result = await Effect.runPromise(
        Effect.scoped(Effect.either(spawnScript(adapter, { scriptName: "missing", cwd: dir }))),
      );
      expect(Either.isLeft(result)).toBe(true);
      if (Either.isLeft(result)) expect(result.left._tag).toBe("ScriptNotDeclared");
      expect(spawns).toEqual([]); // never spawned an undeclared script
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("blocklisted env keys never reach the spawn env; node_modules/.bin is on PATH", async () => {
    const { adapter, spawns } = fakeAdapter();
    await Effect.runPromise(
      Effect.scoped(
        spawnScript(adapter, {
          ...baseOpts,
          cwd: "/proj",
          env: {
            KEEP: "yes",
            PORT: "3000",
            ELECTRON_RUN_AS_NODE: "1",
            PATH: "/usr/bin",
            GONE: undefined,
          },
        }),
      ),
    );
    const env = spawns[0]!.env;
    expect(env.KEEP).toBe("yes");
    expect(env.PORT).toBeUndefined();
    expect(env.ELECTRON_RUN_AS_NODE).toBeUndefined();
    expect(env.GONE).toBeUndefined();
    // node_modules/.bin of the cwd is prepended to PATH (npm-run parity).
    const localBin = join("/proj", "node_modules", ".bin");
    expect(env.PATH!.startsWith(localBin)).toBe(true);
    expect(env.PATH!.endsWith("/usr/bin")).toBe(true);
  });

  it("scope close tree-kills the child (SIGTERM escalation) exactly once", async () => {
    const { adapter, procs } = fakeAdapter();
    await Effect.runPromise(
      Effect.gen(function* () {
        const scope = yield* Scope.make();
        const handle = yield* Scope.extend(spawnScript(adapter, baseOpts), scope);
        expect(yield* handle.isRunning).toBe(true);
        yield* Scope.close(scope, Exit.void);
        expect(procs[0]!.kills).toEqual(["SIGTERM"]);
        expect(yield* handle.isRunning).toBe(false);
      }),
    );
  });

  it("release escalates to SIGKILL when the child ignores the first kill", async () => {
    const { adapter, procs } = fakeAdapter();
    await Effect.runPromise(
      Effect.gen(function* () {
        const scope = yield* Scope.make();
        yield* Scope.extend(spawnScript(adapter, baseOpts), scope);
        const proc = procs[0]!;
        proc.exitOnKill = null; // ignore SIGTERM
        const closing = yield* Effect.fork(Scope.close(scope, Exit.void));
        yield* Effect.sleep("50 millis");
        expect(proc.kills).toEqual(["SIGTERM"]);
        yield* Effect.sleep("1100 millis");
        expect(proc.kills).toEqual(["SIGTERM", "SIGKILL"]);
        proc.emitExit({ exitCode: null, signal: "SIGKILL" });
        yield* Effect.fromFiber(closing);
      }),
    );
  }, 10_000);
});

// --- Real child-process smoke test -----------------------------------------

describe("ScriptRunner real child-process smoke test", () => {
  let dir: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "agent-deck-scriptrun-"));
    // A dev server: print a loopback listening URL, then serve until killed.
    writeFileSync(
      join(dir, "server.cjs"),
      [
        "const http = require('node:http');",
        "const server = http.createServer((req, res) => res.end('ok'));",
        "server.listen(0, '127.0.0.1', () => {",
        "  console.log('listening on http://localhost:' + server.address().port + '/');",
        "});",
        "setInterval(() => {}, 1000);",
      ].join("\n"),
    );
    writeFileSync(
      join(dir, "package.json"),
      JSON.stringify({ name: "scratch", scripts: { dev: "node server.cjs" } }),
    );
  });
  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it("lists + starts the declared dev script, streams output, detects the port, and stop kills it", async () => {
    const runtime = makeServerRuntime();
    try {
      const scope = runtime.runSync(Scope.make());
      const { pid, sawServer, listed } = await runtime.runPromise(
        Effect.gen(function* () {
          const runner = yield* ScriptRunner;
          const listed = yield* runner.listScripts(dir);
          const handle = yield* Scope.extend(runner.spawn({ scriptName: "dev", cwd: dir }), scope);
          expect(handle.pid).toBeGreaterThan(0);

          let server: ScriptEvent | null = null;
          let output = "";
          yield* handle.attach((event) => {
            if (event._tag === "Output") output += event.data;
            if (event._tag === "Server") server = event;
          });
          // Wait for the printed URL to be detected + confirmed by the probe.
          yield* Effect.promise(async () => {
            const deadline = Date.now() + 15_000;
            while (server === null && Date.now() < deadline) {
              await new Promise((resolve) => setTimeout(resolve, 50));
            }
          });
          return { pid: handle.pid, sawServer: server, listed, output };
        }),
      );
      expect(listed).toEqual([{ name: "dev", command: "node server.cjs" }]);
      expect(sawServer).not.toBeNull();
      const server = sawServer as unknown as { server: { host: string; url: string } };
      expect(server.server.host).toBe("localhost");
      expect(server.server.url).toMatch(/^http:\/\/localhost:\d+$/);
      expect(processAlive(pid)).toBe(true);

      // Stop (scope close) tree-kills the child — verified by kill(pid,0) polling.
      await runtime.runPromise(Scope.close(scope, Exit.void));
      await expectProcessGone(pid);
    } finally {
      await runtime.dispose();
    }
  }, 40_000);
});
