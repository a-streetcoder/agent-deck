import { randomUUID } from "node:crypto";
import { copyFileSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { dirname } from "node:path";
import {
  createIngestState,
  emptyTranscript,
  ingestPiEvent,
  reduceTranscript,
  type IngestState,
  type SessionMeta,
  type TranscriptState,
} from "@agent-deck/domain";
import {
  buildLaunchArgs,
  PiSession,
  resolvePiBinary,
  type AgentSessionPlan,
  type LaunchPlan,
  type ModelSelection,
  type PiProcessExit,
} from "@agent-deck/pi-host";
export type { AgentSessionPlan, LaunchPlan };
import { SessionPushBus } from "./pushBus.ts";
import type { ReceiptBus } from "./receipts.ts";

export interface CreateSessionOptions {
  cwd: string;
  plan: LaunchPlan;
  projectId?: string;
  agentName?: string;
  /** Extra env for the pi subprocess (merged over process.env). */
  env?: Record<string, string | undefined>;
}

const TITLE_SYSTEM_PROMPT =
  "You generate a session title. Reply with ONLY a short title (max 8 words) " +
  "summarizing the user's message. No quotes, no punctuation at the end.";

const TITLE_TIMEOUT_MS = 20_000;

function normalizeTitle(raw: string): string {
  const firstLine =
    raw
      .split("\n", 1)[0]
      ?.trim()
      .replace(/^["'"']|["'"']$/g, "") ?? "";
  return firstLine.length > 60 ? `${firstLine.slice(0, 57)}…` : firstLine;
}

/**
 * One live chat session: a PiSession whose events flow through the ingest
 * pipeline into (a) the authoritative in-memory transcript and (b) the ordered
 * push bus that clients subscribe to. Ingestion is synchronous, so stamping
 * happens in pi-stdout order — no async fan-out before seq assignment.
 */
export class ManagedSession {
  readonly bus = new SessionPushBus();
  private readonly ingest: IngestState = createIngestState();
  private transcript: TranscriptState = emptyTranscript();
  private sawFirstDelta = false;
  private titleStarted = false;
  /** Open extension_ui_requests: id → method. Answers must match one. */
  private readonly pendingUiRequests = new Map<string, string>();
  /** While seeding history on resume, live pi events are queued, not applied. */
  private seedGate: Array<Parameters<typeof ingestPiEvent>[1]> | null = null;
  exit: PiProcessExit | null = null;

  constructor(
    readonly meta: SessionMeta,
    private readonly pi: PiSession,
    private readonly receipts: ReceiptBus,
    private readonly onMetaChange: (meta: SessionMeta) => void = () => {},
    /** Provider/model/extensions + env for the isolated title-helper launch. */
    private readonly helperContext?: ModelSelection & {
      extensions?: string[];
      env?: Record<string, string | undefined>;
    },
    /** Temp dirs generated for this launch (bridge extension, memory append
     * file); removed once pi has exited. */
    private readonly tempDirs: string[] = [],
  ) {
    pi.on("event", (piEvent) => {
      if (this.seedGate) {
        this.seedGate.push(piEvent);
        return;
      }
      this.applyPiEvent(piEvent);
    });
    pi.on("exit", (exit) => {
      this.exit = exit;
      this.meta.endedAt = new Date().toISOString();
      this.onMetaChange(this.meta);
      this.cleanupTempDirs();
    });
  }

  /** Remove this launch's generated temp dirs once pi has exited. */
  private cleanupTempDirs(): void {
    for (const dir of this.tempDirs) {
      try {
        rmSync(dir, { recursive: true, force: true });
      } catch {
        // Best-effort: a leftover temp dir is harmless.
      }
    }
  }

  private applyPiEvent(piEvent: Parameters<typeof ingestPiEvent>[1]): void {
    if (piEvent.type === "extension_ui_request") {
      this.pendingUiRequests.set(piEvent.id, piEvent.method);
    }
    for (const domainEvent of ingestPiEvent(this.ingest, piEvent)) {
      this.transcript = reduceTranscript(this.transcript, domainEvent);
      this.bus.append(domainEvent);
      if (domainEvent.type === "cell_delta" && !this.sawFirstDelta) {
        this.sawFirstDelta = true;
        this.receipts.emit("first_delta", this.meta.id);
      }
      if (domainEvent.type === "cell_final" && domainEvent.cell.kind === "assistant") {
        this.receipts.emit("assistant_final", this.meta.id);
      }
      if (domainEvent.type === "agent_status" && domainEvent.status === "idle") {
        this.receipts.emit("idle", this.meta.id);
        this.captureSessionFile();
        void this.generateTitle();
      }
    }
  }

  /** Record pi's canonical session file (the resume handle) once it exists. */
  private captureSessionFile(): void {
    if (this.meta.piSessionFile || !this.pi.isRunning) return;
    void this.pi
      .getState()
      .then((state) => {
        if (state.sessionFile && !this.meta.piSessionFile) {
          this.meta.piSessionFile = state.sessionFile;
          this.onMetaChange(this.meta);
        }
      })
      .catch(() => {
        // Exited or unresponsive — nothing to record.
      });
  }

  /**
   * Isolated title-helper launch (pi-rpc-launch-flags.md §3): no session, no
   * tools, no resources; sends only the first user message.
   */
  private async generateTitle(): Promise<void> {
    if (this.titleStarted || this.meta.title) return;
    const firstUser = this.transcript.cells.find((cell) => cell.kind === "user");
    if (!firstUser || firstUser.kind !== "user" || !firstUser.text.trim()) return;
    this.titleStarted = true;

    const helper = new PiSession({
      binPath: resolvePiBinary().path,
      args: buildLaunchArgs({
        kind: "helper",
        systemPrompt: TITLE_SYSTEM_PROMPT,
        provider: this.helperContext?.provider,
        model: this.helperContext?.model,
        extensions: this.helperContext?.extensions,
      }),
      cwd: this.meta.cwd,
      env: this.helperContext?.env,
      requestTimeoutMs: TITLE_TIMEOUT_MS,
    });
    try {
      const idle = new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error("title helper timeout")), TITLE_TIMEOUT_MS);
        timer.unref();
        helper.on("event", (event) => {
          if ((event as { type: string }).type === "agent_end") {
            clearTimeout(timer);
            resolve();
          }
        });
        helper.on("exit", () => reject(new Error("title helper exited")));
      });
      // Mark handled up front: a startup exit must never become an unhandled
      // rejection while we're still awaiting prompt().
      idle.catch(() => {});
      helper.start();
      await helper.prompt(firstUser.text.slice(0, 2000));
      await idle;
      const { text } = await helper.request({ type: "get_last_assistant_text" });
      const title = text ? normalizeTitle(text) : "";
      if (title) {
        this.meta.title = title;
        this.onMetaChange(this.meta);
        this.receipts.emit("title", this.meta.id);
      }
    } catch {
      this.titleStarted = false; // retry on a later idle
    } finally {
      await helper.stop();
    }
  }

  /** Queue live pi events until seedFromHistory finishes (resume path). */
  holdLiveEvents(): void {
    this.seedGate = [];
  }

  /**
   * Rebuild the transcript from pi's canonical history (resume path). Live
   * events received meanwhile were queued and are applied strictly after the
   * seed, preserving order.
   */
  async seedFromHistory(): Promise<void> {
    try {
      const { messages } = await this.pi.getMessages();
      for (const message of messages) {
        for (const domainEvent of ingestPiEvent(this.ingest, {
          type: "message_end",
          message,
        } as Parameters<typeof ingestPiEvent>[1])) {
          this.transcript = reduceTranscript(this.transcript, domainEvent);
          this.bus.append(domainEvent);
        }
      }
    } finally {
      const queued = this.seedGate ?? [];
      this.seedGate = null;
      for (const piEvent of queued) this.applyPiEvent(piEvent);
    }
  }

  snapshot(): { seq: number; state: TranscriptState } {
    return { seq: this.bus.lastSeq, state: this.transcript };
  }

  get isRunning(): boolean {
    return this.pi.isRunning;
  }

  async prompt(message: string, images?: Parameters<PiSession["prompt"]>[1]): Promise<void> {
    await this.pi.prompt(message, images);
    // Prompting is activity — bump updatedAt (the callback stamps it) so this
    // session sorts to the top of the most-recent-first list.
    this.onMetaChange(this.meta);
  }

  async steer(message: string): Promise<void> {
    await this.pi.steer(message);
  }

  async followUp(message: string): Promise<void> {
    await this.pi.followUp(message);
  }

  async abort(): Promise<void> {
    await this.pi.abort();
  }

  /**
   * Answer an extension UI request. The client's payload is NOT forwarded
   * raw: the id must match an open request and the response is rebuilt here
   * in the exact typed shape pi expects (RpcExtensionUIResponse).
   */
  respondToUiRequest(raw: Record<string, unknown>): void {
    const id = raw.id;
    if (typeof id !== "string" || !this.pendingUiRequests.has(id)) {
      throw new Error("no open extension UI request with that id");
    }
    let response: { type: "extension_ui_response"; id: string } & Record<string, unknown>;
    if (raw.cancelled === true) {
      response = { type: "extension_ui_response", id, cancelled: true };
    } else if (typeof raw.confirmed === "boolean") {
      response = { type: "extension_ui_response", id, confirmed: raw.confirmed };
    } else if (typeof raw.value === "string") {
      response = { type: "extension_ui_response", id, value: raw.value };
    } else {
      throw new Error("ui response must carry cancelled, confirmed, or a string value");
    }
    this.pendingUiRequests.delete(id);
    this.pi.respondToUiRequest(response as Parameters<PiSession["respondToUiRequest"]>[0]);
    // The card is answered from the transcript's point of view immediately.
    const domainEvent = { type: "question_answered", cellId: `question-${id}` } as const;
    this.transcript = reduceTranscript(this.transcript, domainEvent);
    this.bus.append(domainEvent);
  }

  async getCommands(): Promise<Awaited<ReturnType<PiSession["getCommands"]>>> {
    return await this.pi.getCommands();
  }

  async getState(): Promise<Awaited<ReturnType<PiSession["getState"]>>> {
    return await this.pi.getState();
  }

  async getAvailableModels(): Promise<Awaited<ReturnType<PiSession["getAvailableModels"]>>> {
    return await this.pi.getAvailableModels();
  }

  async setModel(provider: string, modelId: string): Promise<void> {
    await this.pi.setModel(provider, modelId);
  }

  async setThinkingLevel(level: Parameters<PiSession["setThinkingLevel"]>[0]): Promise<void> {
    await this.pi.setThinkingLevel(level);
  }

  /** Subscribe to process exit; returns an unsubscribe. Fires immediately if already exited. */
  onExit(listener: (exit: PiProcessExit) => void): () => void {
    if (this.exit) {
      listener(this.exit);
      return () => {};
    }
    this.pi.on("exit", listener);
    return () => this.pi.off("exit", listener);
  }

  /** Rename: update pi's session name (when live) and the persisted title. */
  async rename(title: string): Promise<void> {
    if (this.pi.isRunning) {
      await this.pi.setSessionName(title).catch(() => {
        // Non-fatal: the display title below is authoritative for the UI.
      });
    }
    this.meta.title = title;
    this.onMetaChange(this.meta);
  }

  get piSessionFile(): string | undefined {
    return this.meta.piSessionFile;
  }

  async stop(): Promise<void> {
    await this.pi.stop();
  }
}

export class SessionManager {
  private readonly sessions = new Map<string, ManagedSession>();
  /** In-flight resumes by session id — double-resume returns the same promise. */
  private readonly resuming = new Map<string, Promise<ManagedSession>>();

  constructor(
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
    private readonly bridgeExtensionFactory: (sessionId: string) => string | undefined = () =>
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
    };
    return this.launch(meta, options.plan, options.env);
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
      const session = this.launch(revived, plan, env, { holdLive: true });
      await session.seedFromHistory();
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

  private launch(
    meta: SessionMeta,
    plan: LaunchPlan,
    env?: Record<string, string | undefined>,
    options?: { holdLive?: boolean },
  ): ManagedSession {
    // Inject the app-managed tool bridge (memory/mcp/subagents) for this
    // session. The session id is baked into the generated extension so its
    // calls come back tagged; helper launches never pass through here.
    const tempDirs: string[] = [];
    const bridgeExtension = this.bridgeExtensionFactory(meta.id);
    let launchPlan: LaunchPlan = bridgeExtension
      ? { ...plan, extensions: [...(plan.extensions ?? []), bridgeExtension] }
      : plan;
    if (bridgeExtension) tempDirs.push(dirname(bridgeExtension));
    // Parent sessions get Agent Deck's system-prompt appends (preserved
    // APPEND_SYSTEM.md path, then the memory block). Any explicit append
    // suppresses pi's auto-discovery, so the factory re-adds APPEND_SYSTEM.md
    // ahead of our own; empty leaves pi to discover it.
    if (launchPlan.kind === "parent") {
      // The HOME the pi child will actually see (cross-spawn merges env over
      // process.env), so global APPEND_SYSTEM.md resolves where pi would find it.
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
    const pi = new PiSession({
      binPath: resolvePiBinary().path,
      args: buildLaunchArgs(launchPlan),
      cwd: meta.cwd,
      env,
    });
    const helperContext = {
      provider: plan.provider,
      model: plan.model,
      // Helpers stay resource-free (launch contract §3) except for
      // provider-registration extensions, which custom providers require.
      extensions: this.helperExtensions(),
      env,
    };
    const session = new ManagedSession(
      meta,
      pi,
      this.receipts,
      this.onMetaChange,
      helperContext,
      tempDirs,
    );
    if (options?.holdLive) session.holdLiveEvents();
    this.sessions.set(meta.id, session);
    pi.start();
    this.receipts.emit("session_created", meta.id);
    this.onMetaChange(meta);
    return session;
  }

  get(id: string): ManagedSession | undefined {
    return this.sessions.get(id);
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
    const session = this.launch(meta, plan, env, { holdLive: true });
    await session.seedFromHistory();
    this.onMetaChange(meta);
    return session;
  }

  async stopAll(): Promise<void> {
    await Promise.all([...this.sessions.values()].map((session) => session.stop()));
  }
}
