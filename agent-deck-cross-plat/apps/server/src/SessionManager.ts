import { randomUUID } from "node:crypto";
import { copyFileSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import type { SessionMeta } from "@agent-deck/contracts";
import type { SessionPlanItem, SessionPlanUpdate, TranscriptState } from "@agent-deck/domain";
import {
  buildLaunchArgs,
  resolvePiBinary,
  type AgentSessionPlan,
  type LaunchPlan,
  type ModelSelection,
  type PiProcessExit,
} from "@agent-deck/pi-host";
import { Effect, Exit, Scope } from "effect";
import { runPromiseUnwrapped, runSyncUnwrapped } from "./effectRun.ts";
import type { ReceiptBus } from "./receipts.ts";
import type { ServerRuntime } from "./runtime.ts";
import type { PiSpawnOptions } from "./services/piHost.ts";
import type { StampedEvent } from "./services/pushBus.ts";
import {
  runOneShotHelper,
  SessionManagerService,
  type ChildBridgeFactory,
  type ManagedSessionRuntime,
  type RunHelperOptions,
  type SpawnSessionParams,
} from "./services/sessionManager.ts";

export type { AgentSessionPlan, LaunchPlan };
export type { ChildBridgeFactory, AgentResolver } from "./services/sessionManager.ts";

/**
 * SessionManager — the synchronous class facade over the Slice 5 Effect service
 * (services/sessionManager.ts). It keeps the exact external API the routes,
 * wsHandler and bridge tools depend on, while every session's real lifecycle
 * (pi subprocess, push bus, ingestion fiber) now runs through the server's
 * ManagedRuntime and its PiHost + SessionPushBuses services — this is the slice
 * where the runtime stops being transitional debt and carries production
 * traffic. Callsites become Effect-native at Slice 7 (the transport swap); this
 * facade is the seam that lets them not churn before then. Same pattern
 * `pushBus.ts` used for the bus in Slice 3.
 */

export interface CreateSessionOptions {
  cwd: string;
  plan: LaunchPlan;
  projectId?: string;
  agentName?: string;
  /** Extra env for the pi subprocess (merged over process.env). */
  env?: Record<string, string | undefined>;
  /** Set when this session runs in an isolated git worktree (cwd IS the worktree)
   *  so the fields persist WITH the initial meta — no orphan window. */
  worktree?: { path: string; branch: string; sourceBranch: string };
}

/** A synchronous view of one session's push bus, for the (still class-based)
 * wsHandler: subscribe/replay dispatch synchronously, exactly like the legacy
 * SessionPushBus (see services/pushBus.ts's sync-dispatch note). */
export interface SessionBusView {
  subscribe(subscriber: (stamped: StampedEvent) => void): () => void;
  replayFrom(lastSeq: number): StampedEvent[] | null;
  readonly lastSeq: number;
}

/**
 * One live chat session — the class facade over a {@link ManagedSessionRuntime}.
 * Synchronous operations (bus subscribe, plan edits, snapshot) run the runtime's
 * effects via `runSync`; async pi operations run them on the ManagedRuntime.
 */
export class ManagedSession {
  private ingestionStarted = false;
  private readonly busView: SessionBusView;

  constructor(
    private readonly rt: ManagedSessionRuntime,
    private readonly runtime: ServerRuntime,
    /** The session's own Scope: closing it kills pi and settles everything. */
    private readonly scope: Scope.CloseableScope,
  ) {
    const handle = rt.bus;
    this.busView = {
      subscribe: (subscriber) => {
        const unsubscribe = Effect.runSync(handle.subscribe(subscriber));
        return () => Effect.runSync(unsubscribe);
      },
      replayFrom: (lastSeq) => Effect.runSync(handle.replayFrom(lastSeq)),
      get lastSeq() {
        return Effect.runSync(handle.lastSeq);
      },
    };
  }

  get meta(): SessionMeta {
    return this.rt.meta;
  }

  get bus(): SessionBusView {
    return this.busView;
  }

  /** Fork the ingestion fiber (idempotent). Create forks immediately; resume/fork
   * fork it only AFTER seeding history, so buffered live events apply after. */
  startIngestion(): void {
    if (this.ingestionStarted) return;
    this.ingestionStarted = true;
    this.runtime.runFork(this.rt.ingest);
  }

  appendSubagentProgress(cellId: string, message: string): void {
    runSyncUnwrapped(this.rt.appendSubagentProgress(cellId, message));
  }

  openSupervisorQuestion(req: {
    requestId: string;
    subagentCellId: string;
    method: "need_decision" | "interview_request";
    title: string;
    message?: string;
    options?: string[];
  }): void {
    runSyncUnwrapped(this.rt.openSupervisorQuestion(req));
  }

  answerSupervisorQuestion(requestId: string, answer: string): void {
    runSyncUnwrapped(this.rt.answerSupervisorQuestion(requestId, answer));
  }

  closeSupervisorQuestion(requestId: string, reason: string): void {
    runSyncUnwrapped(this.rt.closeSupervisorQuestion(requestId, reason));
  }

  setPlan(items: SessionPlanItem[]): void {
    runSyncUnwrapped(this.rt.setPlan(items));
  }

  updatePlan(updates: SessionPlanUpdate[]): void {
    runSyncUnwrapped(this.rt.updatePlan(updates));
  }

  restorePlan(items: SessionPlanItem[]): void {
    runSyncUnwrapped(this.rt.restorePlan(items));
  }

  get plan(): SessionPlanItem[] {
    return Effect.runSync(this.rt.plan);
  }

  async runChildAgent(task: string, agentName?: string): Promise<string> {
    return await runPromiseUnwrapped(this.runtime, this.rt.runChildAgent(task, agentName));
  }

  async seedFromHistory(): Promise<void> {
    await runPromiseUnwrapped(this.runtime, this.rt.seedFromHistory);
  }

  snapshot(): { seq: number; state: TranscriptState } {
    return Effect.runSync(this.rt.snapshot);
  }

  get isRunning(): boolean {
    return Effect.runSync(this.rt.isRunning);
  }

  async prompt(
    message: string,
    images?: Parameters<ManagedSessionRuntime["prompt"]>[1],
  ): Promise<void> {
    await runPromiseUnwrapped(this.runtime, this.rt.prompt(message, images));
  }

  async steer(message: string): Promise<void> {
    await runPromiseUnwrapped(this.runtime, this.rt.steer(message));
  }

  async followUp(message: string): Promise<void> {
    await runPromiseUnwrapped(this.runtime, this.rt.followUp(message));
  }

  async compact(): Promise<void> {
    await runPromiseUnwrapped(this.runtime, this.rt.compact);
  }

  async abort(): Promise<void> {
    await runPromiseUnwrapped(this.runtime, this.rt.abort);
  }

  respondToUiRequest(raw: Record<string, unknown>): void {
    runSyncUnwrapped(this.rt.respondToUiRequest(raw));
  }

  async getCommands(): Promise<Effect.Effect.Success<ManagedSessionRuntime["getCommands"]>> {
    return await runPromiseUnwrapped(this.runtime, this.rt.getCommands);
  }

  async getState(): Promise<Effect.Effect.Success<ManagedSessionRuntime["getState"]>> {
    return await runPromiseUnwrapped(this.runtime, this.rt.getState);
  }

  async getSessionStats(): Promise<
    Effect.Effect.Success<ManagedSessionRuntime["getSessionStats"]>
  > {
    return await runPromiseUnwrapped(this.runtime, this.rt.getSessionStats);
  }

  async getAvailableModels(): Promise<
    Effect.Effect.Success<ManagedSessionRuntime["getAvailableModels"]>
  > {
    return await runPromiseUnwrapped(this.runtime, this.rt.getAvailableModels);
  }

  async setModel(provider: string, modelId: string): Promise<void> {
    await runPromiseUnwrapped(this.runtime, this.rt.setModel(provider, modelId));
  }

  async setThinkingLevel(
    level: Parameters<ManagedSessionRuntime["setThinkingLevel"]>[0],
  ): Promise<void> {
    await runPromiseUnwrapped(this.runtime, this.rt.setThinkingLevel(level));
  }

  onExit(listener: (exit: PiProcessExit) => void): () => void {
    return this.rt.onExit(listener);
  }

  async rename(title: string): Promise<void> {
    await runPromiseUnwrapped(this.runtime, this.rt.rename(title));
  }

  get piSessionFile(): string | undefined {
    return this.rt.meta.piSessionFile;
  }

  /** Stop the session: close its Scope (kills pi, runs finalizers), then run the
   * exit handling now so endedAt/exit listeners fire before the caller proceeds
   * (matching the legacy synchronous pi-exit handler ordering). */
  async stop(): Promise<void> {
    await this.runtime.runPromise(Scope.close(this.scope, Exit.void));
    Effect.runSync(this.rt.ensureExitHandled);
  }
}

export class SessionManager {
  private readonly sessions = new Map<string, ManagedSession>();
  /** In-flight resumes by session id — double-resume returns the same promise. */
  private readonly resuming = new Map<string, Promise<ManagedSession>>();

  constructor(
    /** The server's ManagedRuntime (runtime.ts): every session resolves its pi
     * subprocess + push bus through this. */
    private readonly runtime: ServerRuntime,
    private readonly receipts: ReceiptBus,
    private readonly onMetaChange: (meta: SessionMeta) => void = () => {},
    /** Provider-registration extensions — the ONLY ones helper launches load. */
    private readonly helperExtensions: () => string[] | undefined = () => undefined,
    /**
     * Generates a per-session bridge extension exposing app-managed tools (see
     * apps/server/src/bridge.ts), or undefined when none are registered. Applied
     * to real chat launches (create/resume/fork) but never to isolated helper
     * launches, which stay resource-free per the launch-flag contract.
     */
    private readonly bridgeExtensionFactory: (meta: SessionMeta) => string | undefined = () =>
      undefined,
    /**
     * Extra --append-system-prompt values for a parent session, in order — the
     * preserved APPEND_SYSTEM.md path followed by the memory block. Applied to
     * parent launches only (create/resume/fork); returning empty leaves pi to
     * auto-discover APPEND_SYSTEM.md itself. `home` is the HOME the pi child will
     * actually see (env override, else the process home), so the GLOBAL
     * APPEND_SYSTEM.md resolves against the right directory. `cleanupDir` is a
     * temp dir the factory created (the memory block is passed as a file, not a
     * multi-line literal — that is truncated by cmd.exe on Windows) to remove on
     * exit. See agent-deck-system-prompt-logic.md.
     */
    private readonly parentAppendFactory: (
      cwd: string,
      home: string,
    ) => { appends: string[]; cleanupDir?: string } = () => ({ appends: [] }),
    /**
     * Builds a child subagent's contact_supervisor bridge (server-provided).
     * Threaded to each session so runChildAgent can give its children a
     * supervisor channel routed back to the right transcript cell.
     */
    private readonly childBridgeFactory?: ChildBridgeFactory,
    /** Resolves a named agent for `managed_subagent{agent}` delegation. */
    private readonly resolveAgent?: SpawnSessionParams["resolveAgent"],
    /** Live-read autoTitle preference (native autoTitle). */
    private readonly autoTitle: () => boolean = () => true,
  ) {}

  create(options: CreateSessionOptions): ManagedSession {
    const now = new Date().toISOString();
    const meta: SessionMeta = {
      id: randomUUID(),
      cwd: options.cwd,
      createdAt: now,
      updatedAt: now,
      projectId: options.projectId,
      agentName: options.agentName,
      launchPlan: options.plan,
      ...(options.worktree
        ? {
            worktreePath: options.worktree.path,
            worktreeBranch: options.worktree.branch,
            worktreeSourceBranch: options.worktree.sourceBranch,
          }
        : {}),
    };
    const session = this.launch(meta, options.plan, options.env);
    session.startIngestion();
    return session;
  }

  /**
   * Relaunch a persisted session against its pi session file, with the SAME
   * launch shape it was created with, rebuilding the transcript from pi's
   * canonical history before any live events. Concurrent resumes of the same
   * id share one relaunch.
   */
  async resume(
    meta: SessionMeta,
    fallbackPlan: LaunchPlan,
    env?: Record<string, string | undefined>,
  ): Promise<ManagedSession> {
    const inFlight = this.resuming.get(meta.id);
    if (inFlight) return await inFlight;
    // Already live and running → hand it back. launch() would otherwise
    // overwrite the map entry and orphan the old session's still-running pi
    // (the routes guard this too, but the manager must not rely on callers).
    const live = this.sessions.get(meta.id);
    if (live?.isRunning) return live;

    const original = (meta.launchPlan as LaunchPlan | undefined) ?? fallbackPlan;
    let plan: LaunchPlan;
    if (original.kind === "agent") {
      plan = { ...original, sessionDir: undefined, resumeSessionPath: meta.piSessionFile };
    } else if (original.kind === "parent") {
      plan = { ...original, resumeSessionPath: meta.piSessionFile };
    } else {
      plan = original;
    }

    const task = (async () => {
      const revived: SessionMeta = { ...meta, endedAt: undefined };
      const session = this.launch(revived, plan, env);
      try {
        await session.seedFromHistory();
        // The activity plan is app state (not in pi's session file), so restore
        // it from the persisted meta after the pi history is rebuilt.
        //
        // Ordering note: plan_set is emitted here BEFORE startIngestion drains
        // the pi events buffered since spawn — the reverse of the pre-Effect
        // order (buffered-live then plan). This is safe because the plan is
        // mutated ONLY via the set_session_plan/update_session_plan BRIDGE tools
        // (a separate HTTP round-trip, see services/sessionManager setPlan/
        // updatePlan), never from pi's stdout stream — so no buffered pi event
        // can carry a plan mutation that would race the restore. (And on resume
        // pi stays idle until the first prompt, so the buffer is near-empty.)
        // Final plan state is identical to legacy; only intermediate seq
        // numbering differs, which a snapshotting client never observes.
        if (revived.plan && revived.plan.length > 0) session.restorePlan(revived.plan);
        // Now that history is seeded, start draining live events (buffered since
        // spawn) so they apply strictly after the seed.
        session.startIngestion();
      } catch (error) {
        // launch() already spawned pi and registered the session, but seeding
        // failed (pi died / getMessages timed out) BEFORE ingestion was forked,
        // so its exit handling would never run. Tear the half-built session down
        // — destroy() closes its Scope (killing pi) and runs exit handling
        // (endedAt, temp-dir cleanup) — instead of leaking a dead session with
        // an orphaned pi and an unconsumed stdout queue.
        await this.destroy(revived.id).catch(() => {});
        throw error;
      }
      this.onMetaChange(revived);
      return session;
    })();
    this.resuming.set(meta.id, task);
    try {
      return await task;
    } finally {
      this.resuming.delete(meta.id);
    }
  }

  /**
   * Build one session synchronously through the ManagedRuntime: create its
   * Scope, spawn pi + bus + wire ingestion via the SessionManagerService (all
   * non-suspending, so `runSync` returns immediately). Ingestion forking is the
   * caller's (create forks now; resume/fork fork after seeding).
   */
  private launch(
    meta: SessionMeta,
    plan: LaunchPlan,
    env?: Record<string, string | undefined>,
  ): ManagedSession {
    const tempDirs: string[] = [];
    // A throw before the session owns tempDirs would leak them; clean up on any
    // pre-ownership failure.
    let owned = false;
    try {
      const params = this.buildSpawnParams(meta, plan, env, tempDirs);
      const scope = this.runtime.runSync(Scope.make());
      let rt: ManagedSessionRuntime;
      try {
        rt = this.runtime.runSync(
          SessionManagerService.pipe(
            Effect.flatMap((service) => service.spawn(params)),
            Effect.provideService(Scope.Scope, scope),
          ),
        );
      } catch (error) {
        // Spawn failed after the Scope existed — close it so no resource leaks.
        this.runtime.runFork(Scope.close(scope, Exit.void));
        throw error;
      }
      // The session now owns tempDirs cleanup (via its exit handling).
      owned = true;
      try {
        const session = new ManagedSession(rt, this.runtime, scope);
        this.sessions.set(meta.id, session);
        this.receipts.emit("session_created", meta.id);
        this.onMetaChange(meta);
        return session;
      } catch (error) {
        // A throw AFTER a successful spawn (ManagedSession ctor, receipts, the
        // injected onMetaChange) must not orphan the live pi: drop any
        // half-registered entry and fork scope-close (kills pi, awaits exit)
        // followed by the one-shot exit handling (endedAt, temp dirs,
        // listeners) — ingestion was never forked on this path, so nothing
        // else would ever run it.
        this.sessions.delete(meta.id);
        this.runtime.runFork(
          Scope.close(scope, Exit.void).pipe(Effect.andThen(rt.ensureExitHandled)),
        );
        throw error;
      }
    } catch (error) {
      if (!owned) {
        for (const dir of tempDirs) {
          try {
            rmSync(dir, { recursive: true, force: true });
          } catch {
            // Best-effort.
          }
        }
      }
      throw error;
    }
  }

  /** Assemble the pi spawn options + session-build params, applying the bridge
   * extension, parent system-prompt appends, and the agent-prompt temp file —
   * the launch-plan shaping that used to live in `launchWithTemp`. */
  private buildSpawnParams(
    meta: SessionMeta,
    plan: LaunchPlan,
    env: Record<string, string | undefined> | undefined,
    tempDirs: string[],
  ): SpawnSessionParams {
    const bridgeExtension = this.bridgeExtensionFactory(meta);
    let launchPlan: LaunchPlan = bridgeExtension
      ? { ...plan, extensions: [...(plan.extensions ?? []), bridgeExtension] }
      : plan;
    if (bridgeExtension) tempDirs.push(dirname(bridgeExtension));
    // Parent sessions get Agent Deck's system-prompt appends (preserved
    // APPEND_SYSTEM.md path, then the memory block). Any explicit append
    // suppresses pi's auto-discovery, so the factory re-adds APPEND_SYSTEM.md
    // ahead of our own; empty leaves pi to discover it.
    if (launchPlan.kind === "parent") {
      const launchHome = env?.HOME ?? env?.USERPROFILE ?? homedir();
      const { appends, cleanupDir } = this.parentAppendFactory(meta.cwd, launchHome);
      if (appends.length > 0) {
        launchPlan = {
          ...launchPlan,
          appendSystemPrompts: [...appends, ...(launchPlan.appendSystemPrompts ?? [])],
        };
      }
      if (cleanupDir) tempDirs.push(cleanupDir);
    }
    // A MULTI-LINE agent body literal is truncated on Windows (pi runs via a
    // pi.cmd shim through cmd.exe, cutting an argument at the first newline) — pi
    // reads a value that is an existing file path as a file, so route a
    // multi-line agent body through a temp file (single-line bodies stay
    // literal). The temp dir is cleaned up with the others on exit.
    if (launchPlan.kind === "agent" && launchPlan.systemPrompt.text.includes("\n")) {
      const dir = mkdtempSync(join(tmpdir(), "agent-deck-agent-prompt-"));
      tempDirs.push(dir);
      const file = join(dir, "system.md");
      writeFileSync(file, launchPlan.systemPrompt.text);
      launchPlan = {
        ...launchPlan,
        systemPrompt: { ...launchPlan.systemPrompt, text: file },
      };
    }
    const spawn: PiSpawnOptions = {
      binPath: resolvePiBinary().path,
      args: buildLaunchArgs(launchPlan),
      cwd: meta.cwd,
      env,
    };
    return {
      meta,
      spawn,
      receipts: this.receipts,
      onMetaChange: this.onMetaChange,
      helperContext: {
        provider: plan.provider,
        model: plan.model,
        // Helpers stay resource-free (launch contract §3) except for
        // provider-registration extensions, which custom providers require.
        extensions: this.helperExtensions(),
        env,
      } satisfies ModelSelection & {
        extensions?: string[];
        env?: Record<string, string | undefined>;
      },
      tempDirs,
      childBridgeFactory: this.childBridgeFactory,
      resolveAgent: this.resolveAgent,
      autoTitle: this.autoTitle,
    };
  }

  get(id: string): ManagedSession | undefined {
    return this.sessions.get(id);
  }

  /**
   * Run a native subagent for a parent session: launch a child pi with the task
   * (inheriting the parent's provider/model/env) and return its final text.
   * Throws if the parent session is unknown.
   */
  async runSubagent(parentSessionId: string, task: string, agentName?: string): Promise<string> {
    const parent = this.sessions.get(parentSessionId);
    if (!parent) throw new Error(`unknown parent session: ${parentSessionId}`);
    return await parent.runChildAgent(task, agentName);
  }

  /**
   * Run a one-shot pi helper (native commit-message / title generation): an
   * isolated `--no-session --no-tools` launch that answers a single prompt and
   * exits. Returns the final assistant text; throws on timeout / early exit.
   */
  async runHelper(opts: RunHelperOptions): Promise<string> {
    return await runPromiseUnwrapped(this.runtime, runOneShotHelper(opts));
  }

  list(): SessionMeta[] {
    return [...this.sessions.values()].map((session) => session.meta);
  }

  /** Stop and drop a live session from the manager (index removal is caller's). */
  async destroy(id: string): Promise<void> {
    const session = this.sessions.get(id);
    if (!session) return;
    this.sessions.delete(id);
    await session.stop();
  }

  /**
   * Fork/duplicate: copy the source session's canonical pi file and launch a
   * fresh, independent session resumed from the copy. The original is never
   * touched. Requires the source to have a captured pi session file (i.e. at
   * least one turn has happened).
   */
  async fork(
    source: SessionMeta,
    sessionFilePath: string,
    copyTo: string,
    env?: Record<string, string | undefined>,
  ): Promise<ManagedSession> {
    copyFileSync(sessionFilePath, copyTo);
    const meta: SessionMeta = {
      id: randomUUID(),
      cwd: source.cwd,
      createdAt: new Date().toISOString(),
      projectId: source.projectId,
      agentName: source.agentName,
      launchPlan: source.launchPlan,
      piSessionFile: copyTo,
      title: source.title ? `${source.title} (fork)` : undefined,
      plan: source.plan,
    };
    const original = (source.launchPlan as LaunchPlan | undefined) ?? { kind: "parent" };
    let plan: LaunchPlan;
    if (original.kind === "agent") {
      plan = { ...original, sessionDir: undefined, resumeSessionPath: copyTo };
    } else if (original.kind === "parent") {
      plan = { ...original, resumeSessionPath: copyTo };
    } else {
      plan = original;
    }
    const session = this.launch(meta, plan, env);
    try {
      await session.seedFromHistory();
      // plan_set before startIngestion — safe for the same reason as resume()
      // (plans arrive only via bridge tools, never pi stdout).
      if (meta.plan && meta.plan.length > 0) session.restorePlan(meta.plan);
      session.startIngestion();
    } catch (error) {
      // Seeding failed before ingestion was forked — destroy the half-built
      // session so its Scope closes (killing pi) and exit handling runs, rather
      // than leaking a dead session with an orphaned pi (see resume()).
      await this.destroy(meta.id).catch(() => {});
      throw error;
    }
    this.onMetaChange(meta);
    return session;
  }

  async stopAll(): Promise<void> {
    await Promise.all([...this.sessions.values()].map((session) => session.stop()));
    // Symmetric with destroy(): a stopped session must not linger in the map
    // (stopAll is shutdown-only today, but the asymmetry invited misuse).
    this.sessions.clear();
  }
}
