import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { buildLaunchArgs, resolvePiBinary } from "@agent-deck/pi-host";
import {
  MOCK_MODEL_ID,
  MOCK_PROVIDER_ID,
  startMockProvider,
  writeMockProviderExtension,
  type MockProviderServer,
} from "@agent-deck/testkit";
import { Chunk, Effect, Exit, Fiber, Option, Scope, Stream, type Context } from "effect";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { makeServerRuntime, type ServerRuntime } from "../src/runtime.ts";
import { PiHost, type PiStreamItem } from "../src/services/piHost.ts";

/**
 * Slice-4 gate: a REAL pi binary driven end-to-end through the PiHost Effect
 * service — spawn as a scoped resource, one full streamed turn observed via
 * the handle's Stream (>=2 text deltas before agent_end, the enshrined
 * streaming invariant), then a clean scope close that provably leaves NO
 * orphan pi process (the recorded pid must be gone from the OS).
 */

const SCRIPTED_REPLY = "Effect scope owns the pi subprocess lifecycle end to end tonight";

let mock: MockProviderServer;
let runtime: ServerRuntime;
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const cwd = mkdtempSync(path.join(tmpdir(), "pi-effect-it-"));

beforeAll(async () => {
  mock = await startMockProvider({ reply: () => SCRIPTED_REPLY });
  runtime = makeServerRuntime();
});

afterAll(async () => {
  await runtime.dispose();
  await mock.close();
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
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  expect(processAlive(pid)).toBe(false);
}

const isTextDeltaItem = (item: PiStreamItem): item is PiStreamItem & { _tag: "PiEvent" } => {
  if (item._tag !== "PiEvent") return false;
  const event = item.event as {
    type?: string;
    assistantMessageEvent?: { type?: string; delta?: string };
  };
  return event.type === "message_update" && event.assistantMessageEvent?.type === "text_delta";
};

const isAgentEndItem = (item: PiStreamItem): boolean =>
  item._tag === "PiEvent" && (item.event as { type?: string }).type === "agent_end";

describe("real pi through the PiHost Effect service", () => {
  it("spawns via scope, streams a full turn, closes with no orphan process", async () => {
    const extension = writeMockProviderExtension(mock.baseUrl);
    const result = await runtime.runPromise(
      Effect.gen(function* () {
        const piHost = yield* PiHost;
        const scope = yield* Scope.make();
        // The happy path closes the scope mid-effect (that IS the assertion);
        // this backstop only fires on failure, so a broken run can't leak a
        // real pi process (closing an already-closed scope is a no-op).
        return yield* run(piHost, scope).pipe(Effect.ensuring(Scope.close(scope, Exit.void)));
      }),
    );

    function run(piHost: Context.Tag.Service<PiHost>, scope: Scope.CloseableScope) {
      return Effect.gen(function* () {
        const handle = yield* Scope.extend(
          piHost.spawn({
            binPath: resolvePiBinary().path,
            args: buildLaunchArgs({
              kind: "parent",
              extensions: [extension],
              provider: MOCK_PROVIDER_ID,
              model: MOCK_MODEL_ID,
            }),
            cwd,
            // Hermetic HOME: no user settings/auth/sessions are read or written.
            env: {
              HOME: tmpHome,
              USERPROFILE: tmpHome,
              PI_SKIP_VERSION_CHECK: "1",
            },
            requestTimeoutMs: 45_000,
          }),
          scope,
        );
        const pid = Option.getOrThrow(yield* handle.pid);

        // Consume the turn from the handle's Stream (fork first so nothing is
        // missed; the queue buffers from spawn anyway).
        const collector = yield* handle.events.pipe(
          Stream.takeUntil(isAgentEndItem),
          Stream.runCollect,
          Effect.fork,
        );

        // Sanity: RPC correlation against the real binary.
        const state = yield* handle.getState;

        yield* handle.prompt("hello, stream to me");
        const items = Chunk.toArray(
          yield* Fiber.join(collector).pipe(
            Effect.timeoutFail({
              duration: "50 seconds",
              onTimeout: () => new Error("no agent_end from real pi"),
            }),
          ),
        );

        // Clean scope close: release SIGTERMs pi and waits for the real exit.
        yield* Scope.close(scope, Exit.void);
        const exit = yield* handle.exit;
        const running = yield* handle.isRunning;
        return { pid, sessionId: state.sessionId, items, exit, running };
      });
    }

    expect(typeof result.sessionId).toBe("string");
    expect(result.sessionId.length).toBeGreaterThan(0);

    // The enshrined assertion: streaming is visibly incremental via the Stream.
    const deltas = result.items.filter(isTextDeltaItem);
    expect(deltas.length).toBeGreaterThanOrEqual(2);
    const text = deltas
      .map(
        (item) =>
          (item.event as { assistantMessageEvent?: { delta?: string } }).assistantMessageEvent
            ?.delta ?? "",
      )
      .join("");
    expect(text).toBe(SCRIPTED_REPLY);
    expect(result.items.length).toBeGreaterThan(0);
    expect(isAgentEndItem(result.items.at(-1)!)).toBe(true);

    // Scope close settled the exit and — the orphan proof — the OS pid is gone.
    expect(Option.isSome(result.exit)).toBe(true);
    expect(result.running).toBe(false);
    await expectProcessGone(result.pid);

    // The mock provider actually served the request (real HTTP round-trip).
    expect(mock.requests.length).toBeGreaterThan(0);
    expect(mock.requests[0]!.model).toBe(MOCK_MODEL_ID);
  });
});
