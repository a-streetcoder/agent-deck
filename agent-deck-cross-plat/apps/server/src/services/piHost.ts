import {
  PiProcess,
  serializeJsonLine,
  type PiCommand,
  type PiCommandData,
  type PiCommandType,
  type PiInboundEvent,
  type PiProcessExit,
  type PiRpcResponse,
  type PiUiResponse,
} from "@agent-deck/pi-host";
import {
  Context,
  Data,
  Deferred,
  Duration,
  Effect,
  Layer,
  Option,
  Queue,
  Stream,
  type Scope,
} from "effect";

/**
 * PiHost as a scoped Effect service (Slice 4): the pi subprocess lifecycle.
 *
 * File anatomy follows the services/pushBus.ts template:
 *   1. data types + handle interface (effectful API surface)
 *   2. `spawnPiProcess` — the scoped acquire/release implementation
 *   3. `Context.Tag` service class
 *   4. `PiHostLive` Layer — joined into `serverLayers` in ../runtime.ts
 *
 * Unlike the push bus (pure in-memory state, no Scope), a pi handle OWNS an OS
 * process, so `spawn` is a SCOPED resource built with `Effect.acquireRelease`:
 *
 *   - acquire: construct + start a `PiProcess` (packages/pi-host — which stays
 *     pure/portable; this file only builds on its primitives: spawn, LF-framed
 *     stdout lines, capped stderr, graceful stop). All wiring happens BEFORE
 *     start, so no line/exit can be missed.
 *   - release: `PiProcess.stop()` — a process-TREE kill (POSIX: detached
 *     process group signalled via -pid, SIGTERM then SIGKILL after a 3s
 *     grace; Windows: `taskkill /T /F`), resolving only once the child has
 *     actually exited AND its stdout has drained. pi's own children (stdio
 *     MCP servers, subagents) die with it, so closing the scope can never
 *     leave an orphan process or a hanging fiber.
 *
 * ## RPC correlation via Deferred
 *
 * Each `request` allocates a Deferred keyed by a fresh `req-N` id. The stdout
 * line handler completes the matching Deferred (success:false becomes a typed
 * `PiRpcFailure`). The three ways a pending RPC can end are all closed:
 *   - response arrives → Deferred succeeds/fails, entry removed;
 *   - process exits first → the exit handler FAILS every pending Deferred
 *     with `PiExited` (never a hang — the legacy PiSession invariant);
 *   - the awaiting fiber times out or is interrupted → `Effect.onExit`
 *     removes the pending entry, so a late response is dropped exactly like
 *     the legacy timeout path. Timeouts are Effect-native
 *     (`Effect.timeoutFail`), not setTimeout.
 *
 * ## Bridging from Node callbacks: unsafe*, not runSync
 *
 * `PiProcess` delivers lines/exit through synchronous EventEmitter callbacks.
 * Per the pushBus caveat (“no runSync inside service logic”), those callbacks
 * use the sanctioned sync bridges — `Queue.unsafeOffer` (unbounded queue:
 * always succeeds, preserves stdout order) and `Deferred.unsafeDone` — so no
 * runtime capture and no nested run. The `pending` Map and `exitState` are
 * closure-scoped mutable state, only ever touched inside single sync ops /
 * these callbacks (same atomicity rationale as pushBus).
 *
 * ## The event stream
 *
 * `events` is the JSONL stdout feed as a Stream of tagged items: pi events,
 * malformed lines (surfaced, never thrown — legacy parity), and a final
 * `ProcessExit` item after which the stream ENDS (`Stream.takeUntil` keeps the
 * exit item as the last element). PiProcess gates its 'exit' event on stdout
 * being fully drained (child 'exit' alone does NOT imply stdio is drained),
 * so every line pi wrote before dying is offered to the queue BEFORE the
 * terminating `ProcessExit` — a crashing pi's final events are never dropped
 * by the takeUntil. The backing queue is created at acquire
 * time, so events emitted before the consumer starts pulling are buffered,
 * not lost. SINGLE-CONSUMER by design: the queue is consumed competitively
 * and `Stream.fromQueue` pulls in chunks, so run `events` exactly once per
 * handle (fan-out belongs to the push bus, Slice 5’s job). No null sentinels
 * anywhere: absence is `Option` (`exit`, `pid`), errors are tagged.
 *
 * ## Abort / interrupt semantics
 *
 * `abort` is an RPC (pi acks it and finishes the turn with an `agent_end`
 * event), exactly what SessionManager does today — it does NOT kill the
 * process. Killing is the scope’s job. Interrupting a fiber that awaits a
 * response only abandons that response (the command was already written and
 * cannot be unsent — same as the legacy timeout semantics).
 *
 * Spawn failures (ENOENT etc.) follow pi-host’s contract: they surface as an
 * exit (message in stderr) rather than failing `spawn` itself — the first
 * `request` then fails with `PiExited` and `events` yields `ProcessExit`.
 * A write racing OS-level death is safe the same way: PiProcess captures the
 * async stdin 'error' (EPIPE) as stderr diagnostics instead of letting it
 * crash the host, and the exit path fails the pending RPC with `PiExited`.
 *
 * Like Slice 3, production stays on the legacy PiSession path until Slice 5
 * makes SessionManager consume this service; the tests are the consumer.
 */

export const DEFAULT_REQUEST_TIMEOUT_MS = 20_000;

/** Manual compaction blocks on an LLM call — generous timeout, like PiSession. */
const COMPACT_TIMEOUT_MS = 120_000;

export interface PiSpawnOptions {
  binPath: string;
  /** Full launch args (from buildLaunchArgs) — must include `--mode rpc`. */
  args: string[];
  cwd: string;
  env?: Record<string, string | undefined>;
  /** Default timeout for request/response commands (0 disables). */
  requestTimeoutMs?: number;
}

/** pi answered `success: false` for this command. */
export class PiRpcFailure extends Data.TaggedError("PiRpcFailure")<{
  readonly command: PiCommandType;
  readonly reason: string;
  readonly stderr: string;
}> {
  override get message(): string {
    return `pi rejected ${this.command}: ${this.reason}`;
  }
}

/** pi did not respond within the timeout (the process may still be healthy). */
export class PiRpcTimeout extends Data.TaggedError("PiRpcTimeout")<{
  readonly command: PiCommandType;
  readonly timeoutMs: number;
  readonly stderr: string;
}> {
  override get message(): string {
    return `pi did not respond to ${this.command} within ${this.timeoutMs}ms`;
  }
}

/** The pi process exited (or was never reachable) before/while a command ran. */
export class PiExited extends Data.TaggedError("PiExited")<{
  /** None only when the write raced the exit before it was observed. */
  readonly exit: Option.Option<PiProcessExit>;
  readonly stderr: string;
}> {
  override get message(): string {
    const exit = Option.getOrUndefined(this.exit);
    return `pi exited (code=${exit?.code ?? "?"}, signal=${exit?.signal ?? "?"}) before responding`;
  }
}

export type PiRequestError = PiRpcFailure | PiRpcTimeout | PiExited;

/** One element of the JSONL stdout feed. `ProcessExit` is always the last. */
export type PiStreamItem =
  | { readonly _tag: "PiEvent"; readonly event: PiInboundEvent }
  | { readonly _tag: "MalformedLine"; readonly line: string }
  | { readonly _tag: "ProcessExit"; readonly exit: PiProcessExit };

/**
 * One live pi RPC subprocess as a scoped resource. The method surface mirrors
 * pi-host's PiSession (which mirrors pi's own RpcClient), so Slice 5 can swap
 * SessionManager onto it call-for-call.
 */
export interface PiHostHandle {
  /**
   * Send a command and await its correlated response `data`. Fails typed:
   * `PiRpcFailure` (success:false), `PiRpcTimeout`, `PiExited` (process died
   * before responding — a pending RPC NEVER hangs on process death).
   */
  readonly request: <T extends PiCommandType>(
    command: Omit<PiCommand<T>, "id"> & { type: T },
    timeoutMs?: number,
  ) => Effect.Effect<PiCommandData<T>, PiRequestError>;
  /**
   * The ordered stdout feed; ends with a `ProcessExit` item when pi exits.
   * Single-consumer — run exactly once per handle (see module doc).
   */
  readonly events: Stream.Stream<PiStreamItem>;
  /** Answer an extension_ui_request (fire-and-forget write, like PiSession). */
  readonly respondToUiRequest: (response: PiUiResponse) => Effect.Effect<void, PiExited>;
  readonly isRunning: Effect.Effect<boolean>;
  /** The exit record once pi has exited (None while running). */
  readonly exit: Effect.Effect<Option.Option<PiProcessExit>>;
  /** Resolves when pi exits (immediately if it already has). */
  readonly awaitExit: Effect.Effect<PiProcessExit>;
  /** OS pid of the child (None if the spawn itself failed). */
  readonly pid: Effect.Effect<Option.Option<number>>;
  /** Capped stderr capture (diagnostics — included in typed errors too). */
  readonly stderr: Effect.Effect<string>;

  // Convenience wrappers mirroring PiSession's RpcClient-shaped surface.
  readonly prompt: (
    message: string,
    images?: PiCommand<"prompt">["images"],
  ) => Effect.Effect<void, PiRequestError>;
  readonly steer: (message: string) => Effect.Effect<void, PiRequestError>;
  readonly followUp: (message: string) => Effect.Effect<void, PiRequestError>;
  /** Ask pi to stop the current turn (it stays alive and answers with agent_end). */
  readonly abort: Effect.Effect<void, PiRequestError>;
  readonly compact: Effect.Effect<void, PiRequestError>;
  readonly getState: Effect.Effect<PiCommandData<"get_state">, PiRequestError>;
  readonly getMessages: Effect.Effect<PiCommandData<"get_messages">, PiRequestError>;
  readonly getCommands: Effect.Effect<PiCommandData<"get_commands">["commands"], PiRequestError>;
  readonly getSessionStats: Effect.Effect<PiCommandData<"get_session_stats">, PiRequestError>;
  readonly getAvailableModels: Effect.Effect<
    PiCommandData<"get_available_models">["models"],
    PiRequestError
  >;
  readonly setModel: (
    provider: string,
    modelId: string,
  ) => Effect.Effect<PiCommandData<"set_model">, PiRequestError>;
  readonly setThinkingLevel: (
    level: PiCommand<"set_thinking_level">["level"],
  ) => Effect.Effect<void, PiRequestError>;
  readonly setSessionName: (name: string) => Effect.Effect<void, PiRequestError>;
}

interface PendingRpc {
  readonly command: PiCommandType;
  readonly deferred: Deferred.Deferred<unknown, PiRequestError>;
}

/**
 * Spawn one pi subprocess tied to the caller's Scope: closing the scope kills
 * the process (SIGTERM → SIGKILL) and settles everything pending. Never fails:
 * spawn errors surface as an immediate exit (pi-host contract, see module doc).
 */
export const spawnPiProcess = (
  options: PiSpawnOptions,
): Effect.Effect<PiHostHandle, never, Scope.Scope> =>
  Effect.map(
    Effect.acquireRelease(
      Effect.gen(function* () {
        const queue = yield* Queue.unbounded<PiStreamItem>();
        const exitDeferred = yield* Deferred.make<PiProcessExit>();
        const defaultTimeoutMs = options.requestTimeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;

        const proc = new PiProcess({
          binPath: options.binPath,
          args: options.args,
          cwd: options.cwd,
          env: options.env,
        });

        // Closure-scoped mutable state, only ever touched inside single sync
        // ops or the (synchronous) PiProcess callbacks — see the module doc.
        const pending = new Map<string, PendingRpc>();
        let nextRequestId = 0;
        let exitState: Option.Option<PiProcessExit> = Option.none();

        const handleResponse = (response: PiRpcResponse): void => {
          if (!response.id) return;
          const rpc = pending.get(response.id);
          if (!rpc) return;
          pending.delete(response.id);
          if (!response.success) {
            Deferred.unsafeDone(
              rpc.deferred,
              Effect.fail(
                new PiRpcFailure({
                  command: rpc.command,
                  reason: response.error,
                  stderr: proc.stderr,
                }),
              ),
            );
            return;
          }
          Deferred.unsafeDone(
            rpc.deferred,
            Effect.succeed("data" in response ? response.data : undefined),
          );
        };

        proc.on("line", (line) => {
          if (line.trim().length === 0) return;
          let parsed: unknown;
          try {
            parsed = JSON.parse(line);
          } catch {
            Queue.unsafeOffer(queue, { _tag: "MalformedLine", line });
            return;
          }
          if (typeof parsed !== "object" || parsed === null || !("type" in parsed)) {
            Queue.unsafeOffer(queue, { _tag: "MalformedLine", line });
            return;
          }
          if ((parsed as { type: string }).type === "response") {
            handleResponse(parsed as PiRpcResponse);
            return;
          }
          Queue.unsafeOffer(queue, { _tag: "PiEvent", event: parsed as PiInboundEvent });
        });

        proc.on("exit", (exit) => {
          exitState = Option.some(exit);
          // A pending RPC when the process dies must FAIL, never hang.
          for (const rpc of pending.values()) {
            Deferred.unsafeDone(
              rpc.deferred,
              Effect.fail(new PiExited({ exit: exitState, stderr: proc.stderr })),
            );
          }
          pending.clear();
          Deferred.unsafeDone(exitDeferred, Effect.succeed(exit));
          // The terminating stream element (takeUntil keeps it as the last one).
          Queue.unsafeOffer(queue, { _tag: "ProcessExit", exit });
        });

        yield* Effect.sync(() => proc.start());

        const request = <T extends PiCommandType>(
          command: Omit<PiCommand<T>, "id"> & { type: T },
          timeoutMs: number = defaultTimeoutMs,
        ): Effect.Effect<PiCommandData<T>, PiRequestError> =>
          Effect.gen(function* () {
            if (Option.isSome(exitState)) {
              return yield* new PiExited({ exit: exitState, stderr: proc.stderr });
            }
            const deferred = yield* Deferred.make<unknown, PiRequestError>();
            const id = `req-${nextRequestId++}`;
            pending.set(id, { command: command.type, deferred });
            yield* Effect.try({
              try: () => proc.writeLine(serializeJsonLine({ ...command, id })),
              catch: () => new PiExited({ exit: exitState, stderr: proc.stderr }),
            }).pipe(Effect.tapError(() => Effect.sync(() => pending.delete(id))));
            const awaitResponse =
              timeoutMs > 0
                ? Deferred.await(deferred).pipe(
                    Effect.timeoutFail({
                      duration: Duration.millis(timeoutMs),
                      onTimeout: () =>
                        new PiRpcTimeout({
                          command: command.type,
                          timeoutMs,
                          stderr: proc.stderr,
                        }),
                    }),
                  )
                : Deferred.await(deferred);
            // Drop the pending entry however the await ends (response already
            // removed it; timeout/interruption must too, so a late response
            // is ignored instead of completing a dead Deferred).
            const data = yield* awaitResponse.pipe(
              Effect.onExit(() => Effect.sync(() => pending.delete(id))),
            );
            return data as PiCommandData<T>;
          });

        const handle: PiHostHandle = {
          // Identical signature; the cast only bypasses TS's inability to
          // unify two independently-declared generics over the distributive
          // `Extract<RpcCommand, { type: T }>` + `{ type: T }` intersection.
          request: request as PiHostHandle["request"],
          events: Stream.fromQueue(queue).pipe(
            Stream.takeUntil((item) => item._tag === "ProcessExit"),
          ),
          respondToUiRequest: (response) =>
            Effect.try({
              try: () => proc.writeLine(serializeJsonLine(response)),
              catch: () => new PiExited({ exit: exitState, stderr: proc.stderr }),
            }),
          isRunning: Effect.sync(() => proc.isRunning),
          exit: Effect.sync(() => exitState),
          awaitExit: Deferred.await(exitDeferred),
          pid: Effect.sync(() => Option.fromNullable(proc.pid)),
          stderr: Effect.sync(() => proc.stderr),
          prompt: (message, images) => Effect.asVoid(request({ type: "prompt", message, images })),
          steer: (message) => Effect.asVoid(request({ type: "steer", message })),
          followUp: (message) => Effect.asVoid(request({ type: "follow_up", message })),
          abort: Effect.asVoid(request({ type: "abort" })),
          compact: Effect.asVoid(request({ type: "compact" }, COMPACT_TIMEOUT_MS)),
          getState: request({ type: "get_state" }),
          getMessages: request({ type: "get_messages" }),
          getCommands: Effect.map(request({ type: "get_commands" }), (data) => data.commands),
          getSessionStats: request({ type: "get_session_stats" }),
          getAvailableModels: Effect.map(
            request({ type: "get_available_models" }),
            (data) => data.models,
          ),
          setModel: (provider, modelId) => request({ type: "set_model", provider, modelId }),
          setThinkingLevel: (level) =>
            Effect.asVoid(request({ type: "set_thinking_level", level })),
          setSessionName: (name) => Effect.asVoid(request({ type: "set_session_name", name })),
        };

        return { proc, handle };
      }),
      // Release: kill the child's whole process tree (see PiProcess.stop) and
      // wait for the real, drain-gated exit. The exit handler above settles
      // pending RPCs and terminates the stream, so nothing can be left
      // hanging after the scope closes.
      ({ proc }) => Effect.promise(() => proc.stop()),
    ),
    ({ handle }) => handle,
  );

export interface PiHostShape {
  /** Spawn a pi subprocess as a resource of the caller's Scope. */
  readonly spawn: (options: PiSpawnOptions) => Effect.Effect<PiHostHandle, never, Scope.Scope>;
}

/**
 * Factory service: pi processes are per-session, so the runtime-scoped service
 * hands out scoped handles rather than owning one global process.
 */
export class PiHost extends Context.Tag("agent-deck/server/services/PiHost")<
  PiHost,
  PiHostShape
>() {}

export const PiHostLive = Layer.succeed(PiHost, { spawn: spawnPiProcess });
