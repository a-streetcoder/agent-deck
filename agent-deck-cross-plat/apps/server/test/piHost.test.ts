import path from "node:path";
import { fileURLToPath } from "node:url";
import { Chunk, Deferred, Effect, Either, Exit, Fiber, Option, Scope, Stream } from "effect";
import { describe, expect, it } from "vitest";
import { makeServerRuntime } from "../src/runtime.ts";
import {
  PiHost,
  spawnPiProcess,
  type PiSpawnOptions,
  type PiStreamItem,
} from "../src/services/piHost.ts";

/**
 * PiHost service unit tests against a scripted fake subprocess (stdin/stdout
 * JSONL piping, fixtures/fake-pi.cjs) — the process-lifecycle edge cases:
 * scope-close kill, exit-with-pending, stream termination, out-of-order RPC
 * correlation, abort mid-turn.
 */

const FIXTURE = path.join(path.dirname(fileURLToPath(import.meta.url)), "fixtures", "fake-pi.cjs");

const opts = (requestTimeoutMs = 5_000): PiSpawnOptions => ({
  binPath: process.execPath,
  args: [FIXTURE],
  cwd: process.cwd(),
  requestTimeoutMs,
});

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

const isDeltaItem = (item: PiStreamItem): boolean =>
  item._tag === "PiEvent" && (item.event as { type?: string }).type === "message_update";

const isAgentEndItem = (item: PiStreamItem): boolean =>
  item._tag === "PiEvent" && (item.event as { type?: string }).type === "agent_end";

describe("PiHost scoped subprocess service", () => {
  it(
    "scope close kills the child and settles everything pending",
    async () => {
      const result = await Effect.runPromise(
        Effect.gen(function* () {
          const scope = yield* Scope.make();
          const handle = yield* Scope.extend(spawnPiProcess(opts()), scope);
          const pid = Option.getOrThrow(yield* handle.pid);
          expect(yield* handle.isRunning).toBe(true);

          // A stream consumer and a pending RPC (never answered, no timeout)
          // are both in flight when the scope closes.
          const streamFiber = yield* Effect.fork(Stream.runCollect(handle.events));
          const pendingFiber = yield* Effect.fork(handle.request({ type: "compact" }, 0));
          yield* Effect.sleep("50 millis"); // let the compact write reach the child

          yield* Scope.close(scope, Exit.void);

          const pendingResult = yield* Effect.either(Fiber.join(pendingFiber));
          const items = Chunk.toArray(yield* Fiber.join(streamFiber));
          return { pid, pendingResult, items, exit: yield* handle.exit };
        }),
      );

      // Release killed the process and recorded the exit.
      expect(Option.isSome(result.exit)).toBe(true);
      await expectProcessGone(result.pid);
      // The pending RPC FAILED (typed), it did not hang.
      expect(Either.isLeft(result.pendingResult)).toBe(true);
      if (Either.isLeft(result.pendingResult)) {
        expect(result.pendingResult.left._tag).toBe("PiExited");
      }
      // The stream completed, terminated by the ProcessExit item.
      expect(result.items.at(-1)?._tag).toBe("ProcessExit");
    },
    15_000,
  );

  it(
    "child exit mid-command fails pending RPC Deferreds instead of hanging",
    async () => {
      await Effect.runPromise(
        Effect.scoped(
          Effect.gen(function* () {
            const handle = yield* spawnPiProcess(opts());
            // One long-pending RPC, then a command the fixture answers with
            // process.exit(3) and NO response.
            const pendingFiber = yield* Effect.fork(handle.request({ type: "compact" }, 0));
            yield* Effect.sleep("50 millis");
            const exitTrigger = yield* Effect.fork(handle.setSessionName("exit"));

            const exit = yield* handle.awaitExit;
            expect(exit.code).toBe(3);

            const pendingResult = yield* Effect.either(Fiber.join(pendingFiber));
            expect(Either.isLeft(pendingResult)).toBe(true);
            if (Either.isLeft(pendingResult)) {
              expect(pendingResult.left._tag).toBe("PiExited");
              if (pendingResult.left._tag === "PiExited") {
                expect(Option.getOrThrow(pendingResult.left.exit).code).toBe(3);
              }
            }
            const triggerResult = yield* Effect.either(Fiber.join(exitTrigger));
            expect(Either.isLeft(triggerResult)).toBe(true);

            // Requests against the already-exited process fail immediately.
            const late = yield* Effect.either(handle.getState);
            expect(Either.isLeft(late)).toBe(true);
            if (Either.isLeft(late)) expect(late.left._tag).toBe("PiExited");
            expect(yield* handle.isRunning).toBe(false);
          }),
        ),
      );
    },
    15_000,
  );

  it(
    "the event stream terminates with a ProcessExit item when pi exits",
    async () => {
      const items = await Effect.runPromise(
        Effect.scoped(
          Effect.gen(function* () {
            const handle = yield* spawnPiProcess(opts());
            const streamFiber = yield* Effect.fork(Stream.runCollect(handle.events));
            yield* Effect.either(handle.setSessionName("exit"));
            // Fiber.join returning at all proves the stream ENDED on exit.
            return Chunk.toArray(yield* Fiber.join(streamFiber));
          }),
        ),
      );
      const last = items.at(-1);
      expect(last?._tag).toBe("ProcessExit");
      if (last?._tag === "ProcessExit") expect(last.exit.code).toBe(3);
    },
    15_000,
  );

  it("correlates out-of-order responses to their requests", async () => {
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const handle = yield* spawnPiProcess(opts());
          // The fixture delays get_session_stats by 150ms, so get_state's
          // response arrives FIRST although it was issued second.
          const [stats, state] = yield* Effect.all(
            [handle.getSessionStats, handle.getState],
            { concurrency: "unbounded" },
          );
          expect(state.sessionId).toBe("fake-session");
          expect((stats as unknown as { tokens: number }).tokens).toBe(123);
        }),
      ),
    );
  }, 15_000);

  it("fails with PiRpcFailure carrying pi's error on success:false", async () => {
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const handle = yield* spawnPiProcess(opts());
          const failure = yield* Effect.flip(handle.setSessionName("fail"));
          expect(failure._tag).toBe("PiRpcFailure");
          expect(failure.message).toContain("boom");
        }),
      ),
    );
  }, 15_000);

  it("times out a request Effect-natively and stays usable afterwards", async () => {
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const handle = yield* spawnPiProcess(opts());
          const failure = yield* Effect.flip(handle.request({ type: "compact" }, 200));
          expect(failure._tag).toBe("PiRpcTimeout");
          // The process is untouched by the timeout: further RPCs still work.
          const state = yield* handle.getState;
          expect(state.sessionId).toBe("fake-session");
        }),
      ),
    );
  }, 15_000);

  it("interrupting a fiber awaiting a response abandons only that RPC", async () => {
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const handle = yield* spawnPiProcess(opts());
          const fiber = yield* Effect.fork(handle.request({ type: "compact" }, 0));
          yield* Effect.sleep("50 millis");
          yield* Fiber.interrupt(fiber);
          // The handle is unaffected — correlation state was cleaned up.
          const state = yield* handle.getState;
          expect(state.sessionId).toBe("fake-session");
        }),
      ),
    );
  }, 15_000);

  it(
    "abort mid-turn stops the delta stream with agent_end, process stays alive",
    async () => {
      await Effect.runPromise(
        Effect.scoped(
          Effect.gen(function* () {
            const handle = yield* spawnPiProcess(opts());
            const sawTwoDeltas = yield* Deferred.make<void>();
            let deltas = 0;
            const collector = yield* handle.events.pipe(
              Stream.tap((item) => {
                if (isDeltaItem(item)) {
                  deltas += 1;
                  if (deltas === 2) return Deferred.succeed(sawTwoDeltas, void 0);
                }
                return Effect.void;
              }),
              Stream.takeUntil(isAgentEndItem),
              Stream.runCollect,
              Effect.fork,
            );

            // "stream-forever" only ends when aborted — a real mid-turn abort.
            yield* handle.prompt("stream-forever");
            yield* Deferred.await(sawTwoDeltas);
            yield* handle.abort;

            const items = Chunk.toArray(yield* Fiber.join(collector));
            expect(items.filter(isDeltaItem).length).toBeGreaterThanOrEqual(2);
            expect(items.at(-1) && isAgentEndItem(items.at(-1)!)).toBe(true);
            // Abort finishes the TURN, not the process.
            expect(yield* handle.isRunning).toBe(true);
          }),
        ),
      );
    },
    15_000,
  );

  it("surfaces malformed stdout lines in-stream without breaking it", async () => {
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const handle = yield* spawnPiProcess(opts());
          const collector = yield* handle.events.pipe(
            Stream.takeUntil(isAgentEndItem),
            Stream.runCollect,
            Effect.fork,
          );
          yield* handle.prompt("hi");
          const items = Chunk.toArray(yield* Fiber.join(collector));
          const tags = items.map((item) =>
            item._tag === "PiEvent" ? (item.event as { type?: string }).type : item._tag,
          );
          expect(tags).toEqual([
            "turn_start",
            "message_update",
            "MalformedLine",
            "message_update",
            "agent_end",
          ]);
          const malformed = items.find((item) => item._tag === "MalformedLine");
          expect(malformed && malformed._tag === "MalformedLine" && malformed.line).toBe(
            "this is not json",
          );
        }),
      ),
    );
  }, 15_000);

  it(
    "delivers stdout lines still buffered at death before the ProcessExit item",
    async () => {
      const items = await Effect.runPromise(
        Effect.scoped(
          Effect.gen(function* () {
            const handle = yield* spawnPiProcess(opts());
            const streamFiber = yield* Effect.fork(Stream.runCollect(handle.events));
            // burst-exit writes 200 events and dies the instant the OS pipe
            // has the bytes — the drain-gated exit must deliver every one of
            // them before the stream's terminating ProcessExit.
            yield* Effect.either(handle.setSessionName("burst-exit"));
            return Chunk.toArray(yield* Fiber.join(streamFiber));
          }),
        ),
      );
      const burstNs = items
        .filter((item): item is Extract<PiStreamItem, { _tag: "PiEvent" }> => item._tag === "PiEvent")
        .map((item) => item.event as { type?: string; n?: number })
        .filter((event) => event.type === "burst")
        .map((event) => event.n);
      expect(burstNs).toEqual(Array.from({ length: 200 }, (_, i) => i));
      const last = items.at(-1);
      expect(last?._tag).toBe("ProcessExit");
      if (last?._tag === "ProcessExit") expect(last.exit.code).toBe(7);
    },
    15_000,
  );

  it(
    "scope close reaps pi's own children too (tree kill)",
    async () => {
      const result = await Effect.runPromise(
        Effect.gen(function* () {
          const scope = yield* Scope.make();
          const handle = yield* Scope.extend(spawnPiProcess(opts()), scope);
          const pid = Option.getOrThrow(yield* handle.pid);
          // Ask the fixture to spawn a long-lived grandchild (a stand-in for
          // pi's stdio MCP servers / subagents); it reports the pid in-stream.
          const childPidFiber = yield* Effect.fork(
            handle.events.pipe(
              Stream.filter(
                (item): item is Extract<PiStreamItem, { _tag: "PiEvent" }> =>
                  item._tag === "PiEvent" &&
                  (item.event as { type?: string }).type === "child_pid",
              ),
              Stream.runHead,
            ),
          );
          yield* handle.setSessionName("spawn-child");
          const childItem = Option.getOrThrow(yield* Fiber.join(childPidFiber));
          const childPid = (childItem.event as unknown as { pid: number }).pid;
          expect(processAlive(pid)).toBe(true);
          expect(processAlive(childPid)).toBe(true);

          yield* Scope.close(scope, Exit.void);
          return { pid, childPid };
        }),
      );
      // Release killed the TREE: the direct child AND its child are gone.
      await expectProcessGone(result.pid);
      await expectProcessGone(result.childPid);
    },
    15_000,
  );

  it(
    "a request write racing OS-level death fails typed instead of crashing",
    async () => {
      await Effect.runPromise(
        Effect.scoped(
          Effect.gen(function* () {
            const handle = yield* spawnPiProcess(opts());
            const pid = Option.getOrThrow(yield* handle.pid);
            const state = yield* handle.getState;
            expect(state.sessionId).toBe("fake-session");
            // SIGKILL at the OS level, then write in the same tick: the
            // 'exit' event needs a later event-loop turn, so the guard in
            // writeLine cannot see the death yet and the write lands on a
            // dead pipe. The async stdin 'error' (EPIPE) must be swallowed
            // (not crash the worker) and the RPC must fail typed via the
            // exit path.
            const result = yield* Effect.suspend(() => {
              process.kill(pid, "SIGKILL");
              return Effect.either(handle.request({ type: "get_state" }));
            });
            expect(Either.isLeft(result)).toBe(true);
            if (Either.isLeft(result)) expect(result.left._tag).toBe("PiExited");
            expect(yield* handle.isRunning).toBe(false);
          }),
        ),
      );
    },
    15_000,
  );

  it("serves scoped handles through the PiHost tag and serverLayers", async () => {
    const runtime = makeServerRuntime();
    try {
      const state = await runtime.runPromise(
        Effect.scoped(
          Effect.gen(function* () {
            const piHost = yield* PiHost;
            const handle = yield* piHost.spawn(opts());
            return yield* handle.getState;
          }),
        ),
      );
      expect(state.sessionId).toBe("fake-session");
    } finally {
      await runtime.dispose();
    }
  }, 15_000);
});
