import { randomUUID } from "node:crypto";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { DomainEvent, SessionMeta } from "@agent-deck/domain";
import { Effect, Exit, Layer, ManagedRuntime, Option, Scope } from "effect";
import { afterEach, describe, expect, it } from "vitest";
import { SessionManager } from "../src/SessionManager.ts";
import { ReceiptBus, type ReceiptName } from "../src/receipts.ts";
import type { ServerRuntime } from "../src/runtime.ts";
import { PiHostLive, spawnPiProcess, type PiHostShape } from "../src/services/piHost.ts";
import {
  makeSessionPushBusHandle,
  SessionPushBusesLive,
  type SessionPushBusHandle,
  type SessionPushBusesShape,
} from "../src/services/pushBus.ts";
import {
  makeManagedSessionRuntime,
  SessionManagerService,
  type ManagedSessionRuntime,
  type SpawnSessionParams,
} from "../src/services/sessionManager.ts";

/**
 * SessionManager service unit tests (Slice 5) against the scripted fake pi
 * (fixtures/fake-pi.cjs). These cover the concurrency-critical new code the
 * real-pi e2e tests do not assert: the ingestion fiber lifecycle + stdout
 * ordering, per-session Scope teardown killing pi and running exit handling
 * exactly once, the title fiber being tied to the session Scope (no orphaned
 * helper pi on stop), the ingestion fiber surviving a throwing bus subscriber,
 * and the facade destroying a half-built session when history seeding fails.
 */

const FIXTURE = path.join(path.dirname(fileURLToPath(import.meta.url)), "fixtures", "fake-pi.cjs");

const buses: SessionPushBusesShape = { make: (capacity) => makeSessionPushBusHandle(capacity) };

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

/**
 * A PiHost that redirects EVERY spawn — the main pi AND the internal title /
 * subagent helpers, which all flow through `piHost.spawn` — to the scripted
 * fake-pi, capturing each child's pid in spawn order. `options.env` is preserved
 * (so a helper launched with FAKE_PI_HANG hangs); `binPath`/`args` are ignored.
 */
function makeFakePiHost(): { piHost: PiHostShape; pids: number[] } {
  const pids: number[] = [];
  const piHost: PiHostShape = {
    spawn: (options) =>
      spawnPiProcess({
        binPath: process.execPath,
        args: [FIXTURE],
        cwd: options.cwd,
        env: options.env,
        requestTimeoutMs: options.requestTimeoutMs,
      }).pipe(
        Effect.tap((handle) =>
          Effect.map(handle.pid, (pid) => {
            if (Option.isSome(pid)) pids.push(pid.value);
          }),
        ),
      ),
  };
  return { piHost, pids };
}

const tempDirsToClean: string[] = [];
function makeTempDir(): string {
  const dir = mkdtempSync(path.join(tmpdir(), "agent-deck-sm-test-"));
  tempDirsToClean.push(dir);
  return dir;
}
afterEach(() => {
  for (const dir of tempDirsToClean.splice(0)) {
    try {
      rmSync(dir, { recursive: true, force: true });
    } catch {
      // best-effort
    }
  }
});

function makeParams(overrides: Partial<SpawnSessionParams> = {}): SpawnSessionParams {
  const meta: SessionMeta = {
    id: randomUUID(),
    cwd: process.cwd(),
    createdAt: new Date().toISOString(),
  };
  return {
    meta,
    spawn: { binPath: process.execPath, args: [FIXTURE], cwd: process.cwd() },
    receipts: new ReceiptBus(false),
    onMetaChange: () => {},
    helperContext: {},
    tempDirs: [],
    autoTitle: () => false,
    ...overrides,
  };
}

const waitUntil = (pred: () => boolean, ms = 5_000): Effect.Effect<void> =>
  Effect.gen(function* () {
    const deadline = Date.now() + ms;
    while (!pred() && Date.now() < deadline) yield* Effect.sleep("25 millis");
    if (!pred()) yield* Effect.die(new Error("waitUntil: condition not met in time"));
  });

describe("SessionManager Effect service (services/sessionManager.ts)", () => {
  it("ingestion fiber folds pi stdout into ordered domain events on the bus", async () => {
    const { piHost } = makeFakePiHost();
    const out = await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const rt = yield* makeManagedSessionRuntime(piHost, buses, makeParams());
          const seen: DomainEvent[] = [];
          yield* rt.bus.subscribe((s) => seen.push(s.event));
          yield* Effect.forkDaemon(rt.ingest);
          yield* rt.prompt("say-hello");
          yield* waitUntil(() =>
            seen.some((e) => e.type === "cell_final" && e.cell.kind === "assistant"),
          );
          return { seen, snap: yield* rt.snapshot };
        }),
      ),
    );
    // fake-pi streams "he" + "llo" (with a malformed line in between, ignored).
    const assistant = out.snap.state.cells.find((c) => c.kind === "assistant");
    const text =
      assistant?.kind === "assistant" ? assistant.blocks.map((b) => b.text).join("") : "";
    expect(text).toContain("hello");
    // Deltas were stamped onto the bus BEFORE the assistant's cell_final — the
    // pi-stdout order the single synchronous `emit` seam preserves.
    const firstDelta = out.seen.findIndex((e) => e.type === "cell_delta");
    const finalIdx = out.seen.findIndex(
      (e) => e.type === "cell_final" && e.cell.kind === "assistant",
    );
    expect(firstDelta).toBeGreaterThanOrEqual(0);
    expect(firstDelta).toBeLessThan(finalIdx);
  }, 15_000);

  it("closing the session Scope kills pi and runs exit handling once (endedAt, temp cleanup, listeners)", async () => {
    const { piHost, pids } = makeFakePiHost();
    const tempDir = makeTempDir();
    const meta: SessionMeta = {
      id: randomUUID(),
      cwd: process.cwd(),
      createdAt: new Date().toISOString(),
    };
    let exitCount = 0;
    const out = await Effect.runPromise(
      Effect.gen(function* () {
        const scope = yield* Scope.make();
        const rt = yield* Scope.extend(
          makeManagedSessionRuntime(piHost, buses, makeParams({ meta, tempDirs: [tempDir] })),
          scope,
        );
        rt.onExit(() => {
          exitCount += 1;
        });
        yield* Effect.forkDaemon(rt.ingest);
        yield* Effect.sleep("50 millis"); // let the ingestion fiber claim the feed
        const aliveBefore = processAlive(pids[0]!);
        // Scope close == pi killed; the ingestion fiber then processes the
        // terminating ProcessExit item and runs the idempotent exit handling.
        yield* Scope.close(scope, Exit.void);
        yield* waitUntil(() => rt.meta.endedAt !== undefined);
        return { aliveBefore, endedAt: rt.meta.endedAt, mainPid: pids[0]! };
      }),
    );
    expect(out.aliveBefore).toBe(true);
    await expectProcessGone(out.mainPid);
    expect(out.endedAt).toBeDefined();
    expect(exitCount).toBe(1); // runExitHandling is guarded — fires exactly once
    expect(existsSync(tempDir)).toBe(false); // temp dirs cleaned on exit
  }, 15_000);

  it("receipt cardinality: first_delta once EVER, assistant_final/idle once PER TURN", async () => {
    const { piHost } = makeFakePiHost();
    const emitted: string[] = [];
    class RecordingReceipts extends ReceiptBus {
      override emit(name: ReceiptName, sessionId: string): void {
        emitted.push(name);
        super.emit(name, sessionId);
      }
    }
    const count = (name: string): number => emitted.filter((n) => n === name).length;
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const rt = yield* makeManagedSessionRuntime(
            piHost,
            buses,
            makeParams({ receipts: new RecordingReceipts(true) }),
          );
          yield* Effect.forkDaemon(rt.ingest);
          yield* rt.prompt("say-hello");
          yield* waitUntil(() => count("idle") >= 1);
          // Turn 1: exactly one of each.
          expect(count("first_delta")).toBe(1);
          expect(count("assistant_final")).toBe(1);
          expect(count("idle")).toBe(1);
          yield* rt.prompt("say-hello");
          yield* waitUntil(() => count("idle") >= 2);
          // Turn 2: per-turn receipts fire again; first_delta stays one-shot,
          // and no title receipt (autoTitle() => false in makeParams).
          expect(count("first_delta")).toBe(1);
          expect(count("assistant_final")).toBe(2);
          expect(count("idle")).toBe(2);
          expect(count("title")).toBe(0);
        }),
      ),
    );
  }, 15_000);

  it("a throwing bus subscriber cannot kill the ingestion fiber (per-item defect swallow)", async () => {
    const { piHost } = makeFakePiHost();
    const seen = await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const rt = yield* makeManagedSessionRuntime(piHost, buses, makeParams());
          const recorded: DomainEvent[] = [];
          // recorder FIRST, thrower SECOND: every event reaches the recorder,
          // then the thrower turns `emit` into a DEFECT (not a typed failure).
          yield* rt.bus.subscribe((s) => recorded.push(s.event));
          yield* rt.bus.subscribe(() => {
            throw new Error("boom subscriber");
          });
          yield* Effect.forkDaemon(rt.ingest);
          yield* rt.prompt("say-hello");
          // If defects killed the fiber, only the FIRST event would ever arrive
          // and no assistant cell_final would be recorded (session frozen).
          yield* waitUntil(() =>
            recorded.some((e) => e.type === "cell_final" && e.cell.kind === "assistant"),
          );
          return recorded;
        }),
      ),
    );
    expect(seen.some((e) => e.type === "cell_final" && e.cell.kind === "assistant")).toBe(true);
    expect(seen.filter((e) => e.type === "cell_delta").length).toBeGreaterThanOrEqual(1);
  }, 15_000);

  it("forks the title fiber into the session Scope: scope close reaps an in-flight title helper pi", async () => {
    const { piHost, pids } = makeFakePiHost();
    const out = await Effect.runPromise(
      Effect.gen(function* () {
        const scope = yield* Scope.make();
        const rt = yield* Scope.extend(
          makeManagedSessionRuntime(
            piHost,
            buses,
            makeParams({ autoTitle: () => true, helperContext: { env: { FAKE_PI_HANG: "1" } } }),
          ),
          scope,
        );
        // Seed a first user cell (fake-pi get_messages), then start ingestion
        // (resume ordering), then a turn that reaches idle → the title helper is
        // forked into the session Scope. Its prompt hangs (FAKE_PI_HANG), so the
        // helper pi stays alive until the scope closes.
        yield* rt.seedFromHistory;
        yield* Effect.forkDaemon(rt.ingest);
        yield* rt.prompt("hi");
        yield* waitUntil(() => pids.length >= 2); // [0] main pi, [1] title helper
        const helperPid = pids[1]!;
        const aliveBefore = processAlive(helperPid);
        yield* Scope.close(scope, Exit.void);
        return { helperPid, mainPid: pids[0]!, aliveBefore };
      }),
    );
    expect(out.aliveBefore).toBe(true);
    // With the old `forkDaemon` onto the global runtime the helper would survive
    // scope close (orphaned); forked into the session Scope it is interrupted and
    // its pi reaped.
    await expectProcessGone(out.helperPid);
    await expectProcessGone(out.mainPid);
  }, 20_000);
});

describe("SessionManager facade cleanup on a seed failure (resume/fork)", () => {
  /**
   * A ServerRuntime whose SessionManagerService hands out a session runtime that
   * FAILS history seeding as a defect (exactly like the real `seedFromHistory`,
   * which does `getMessages.pipe(Effect.orDie)`), with a spy on `ensureExitHandled`
   * so the test can assert the facade tore the half-built session down.
   */
  function makeFakeRuntime(): { runtime: ServerRuntime; exitHandledCalls: () => number } {
    let calls = 0;
    const fakeBus: SessionPushBusHandle = {
      lastSeq: Effect.succeed(0),
      append: () => Effect.succeed({ seq: 0, event: {} as DomainEvent }),
      replayFrom: () => Effect.succeed(null),
      subscribe: () => Effect.succeed(Effect.void),
      unsafeAppend: () => ({ seq: 0, event: {} as DomainEvent }),
      unsafeLastSeq: () => 0,
    };
    const fakeSpawn = (
      params: SpawnSessionParams,
    ): Effect.Effect<ManagedSessionRuntime, never, Scope.Scope> =>
      Effect.succeed({
        meta: params.meta,
        bus: fakeBus,
        ingest: Effect.void,
        seedFromHistory: Effect.die(new Error("seed failed: pi exited")),
        ensureExitHandled: Effect.sync(() => {
          calls += 1;
        }),
      } as unknown as ManagedSessionRuntime);
    const layers = Layer.mergeAll(
      Layer.succeed(SessionManagerService, { spawn: fakeSpawn }),
      SessionPushBusesLive,
      PiHostLive,
    );
    const runtime = ManagedRuntime.make(layers) as ServerRuntime;
    return { runtime, exitHandledCalls: () => calls };
  }

  it("resume() destroys the half-built session when history seeding fails", async () => {
    const { runtime, exitHandledCalls } = makeFakeRuntime();
    try {
      const sm = new SessionManager(runtime, new ReceiptBus(false));
      const meta: SessionMeta = {
        id: randomUUID(),
        cwd: process.cwd(),
        createdAt: new Date().toISOString(),
        launchPlan: { kind: "parent" },
      };
      await expect(sm.resume(meta, { kind: "parent" })).rejects.toThrow();
      // launch() spawned + registered the session; the seed failure must tear it
      // back down rather than leak a dead session with an orphaned pi.
      expect(sm.get(meta.id)).toBeUndefined();
      expect(exitHandledCalls()).toBe(1);
    } finally {
      await runtime.dispose();
    }
  });

  it("fork() destroys the half-built session when history seeding fails", async () => {
    const { runtime, exitHandledCalls } = makeFakeRuntime();
    const dir = makeTempDir();
    const srcFile = path.join(dir, "src.jsonl");
    writeFileSync(srcFile, "{}\n");
    const copyTo = path.join(dir, "copy.jsonl");
    try {
      const sm = new SessionManager(runtime, new ReceiptBus(false));
      const source: SessionMeta = {
        id: randomUUID(),
        cwd: process.cwd(),
        createdAt: new Date().toISOString(),
        launchPlan: { kind: "parent" },
        piSessionFile: srcFile,
      };
      await expect(sm.fork(source, srcFile, copyTo)).rejects.toThrow();
      // The freshly-forked session (its own id) must be gone, not leaked.
      expect(sm.list()).toHaveLength(0);
      expect(exitHandledCalls()).toBe(1);
    } finally {
      await runtime.dispose();
    }
  });
});
