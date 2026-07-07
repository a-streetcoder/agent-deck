import { randomUUID } from "node:crypto";
import { copyFileSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
  createIngestState,
  emptyTranscript,
  ingestPiEvent,
  reduceTranscript,
  type DomainEvent,
  type IngestState,
  type SessionMeta,
  type SessionPlanItem,
  type SessionPlanUpdate,
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

/**
 * Builds a child subagent's `contact_supervisor` bridge for one run: returns the
 * generated extension path (loaded via --extension) and a dispose() that tears
 * down the child's bridge token + supervisor route + temp dir. Returns undefined
 * when no supervisor channel is available (e.g. the bridge endpoint isn't bound),
 * in which case the child runs tool-less as before. The server implements this;
 * `route` tells it which parent transcript cell the child's progress flows into.
 */
export type ChildBridgeFactory = (
  childSessionId: string,
  route: { parentSessionId: string; cellId: string },
) => { extension: string; dispose: () => void } | undefined;

/** Resolves a named agent (for `managed_subagent{agent}`) to its persona body,
 * scoped to the delegating session's project. Returns undefined if not found. */
export type AgentResolver = (name: string, projectId?: string) => { body: string } | undefined;

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

const SUBAGENT_SYSTEM_PROMPT =
  "You are a focused subagent launched by Agent Deck to complete one task and " +
  "report back. You have no conversation history. Do the task, then give a " +
  "concise, self-contained result the parent agent can use directly.";

const SUBAGENT_TIMEOUT_MS = 120_000;

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
    /** Builds a child subagent's contact_supervisor bridge (server-provided). */
    private readonly childBridgeFactory?: ChildBridgeFactory,
    /** Resolves a named agent for `managed_subagent{agent}` delegation. */
    private readonly resolveAgent?: AgentResolver,
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

  /**
   * Apply one domain event to the authoritative transcript and stamp it onto the
   * ordered push bus. The single seam through which both pi-derived events and
   * synthetic ones (native subagent cards) reach clients, so ordering stays in
   * pi-stdout order — everything is synchronous up to the bus.
   */
  private emitDomain(event: DomainEvent): void {
    this.transcript = reduceTranscript(this.transcript, event);
    this.bus.append(event);
  }

  /**
   * Append a child subagent's non-blocking progress update to its card in this
   * (the parent's) transcript. Called by the server's supervisor handler when a
   * child invokes contact_supervisor{progress_update}. No-op if the cell is gone.
   */
  appendSubagentProgress(cellId: string, message: string): void {
    this.emitDomain({ type: "subagent_progress", cellId, message });
  }

  /**
   * Open a BLOCKING supervisor-request card in this (the parent's) transcript
   * when a child raises contact_supervisor{need_decision|interview_request}. The
   * child stays suspended until the card is answered.
   */
  openSupervisorQuestion(req: {
    requestId: string;
    subagentCellId: string;
    method: "need_decision" | "interview_request";
    title: string;
    message?: string;
    options?: string[];
  }): void {
    this.emitDomain({
      type: "cell_open",
      cell: {
        kind: "supervisor_question",
        id: `supervisor-${req.requestId}`,
        requestId: req.requestId,
        subagentCellId: req.subagentCellId,
        method: req.method,
        title: req.title,
        message: req.message,
        options: req.options,
        answered: false,
      },
    });
  }

  /** Mark a supervisor-request card answered (with the answer text) in this transcript. */
  answerSupervisorQuestion(requestId: string, answer: string): void {
    this.emitDomain({ type: "supervisor_answered", cellId: `supervisor-${requestId}`, answer });
  }

  /** Close a supervisor-request card WITHOUT an answer (timed out / subagent ended). */
  closeSupervisorQuestion(requestId: string, reason: string): void {
    this.emitDomain({ type: "supervisor_closed", cellId: `supervisor-${requestId}`, reason });
  }

  /** Replace this session's activity plan (set_session_plan). */
  setPlan(items: SessionPlanItem[]): void {
    this.emitDomain({ type: "plan_set", items });
    this.persistPlan();
  }

  /** Patch plan items by id (update_session_plan). */
  updatePlan(updates: SessionPlanUpdate[]): void {
    this.emitDomain({ type: "plan_update", updates });
    this.persistPlan();
  }

  /**
   * Restore a persisted plan into a resumed session's transcript (the plan is
   * app state, not in pi's session file, so seedFromHistory can't rebuild it).
   */
  restorePlan(items: SessionPlanItem[]): void {
    if (items.length === 0) return;
    this.emitDomain({ type: "plan_set", items });
  }

  /** Mirror the current plan onto the meta so the session index persists it. */
  private persistPlan(): void {
    this.meta.plan = this.transcript.plan;
    this.onMetaChange(this.meta);
  }

  /** The session's current activity plan. */
  get plan(): SessionPlanItem[] {
    return this.transcript.plan;
  }

  private applyPiEvent(piEvent: Parameters<typeof ingestPiEvent>[1]): void {
    if (piEvent.type === "extension_ui_request") {
      this.pendingUiRequests.set(piEvent.id, piEvent.method);
    }
    for (const domainEvent of ingestPiEvent(this.ingest, piEvent)) {
      this.emitDomain(domainEvent);
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

  /**
   * Run a native subagent (native-subagent-bridge.md): launch a fresh child
   * `pi --mode rpc` with the given task as its system prompt, no conversation
   * history and no tools, using the parent's provider/model/env (like the title
   * helper). Await the child's turn and return its final assistant text for the
   * parent tool result.
   *
   * The child's transcript is ALSO streamed into the parent as a native
   * "Subagent" card: a subagent cell opens when the child starts, accumulates
   * the child's assistant text deltas, and finalizes with the child's
   * authoritative output. The returned text (the tool result the model sees) is
   * unchanged — the card is purely the visible surface. Runs concurrently under
   * managed_parallel: each child owns a distinct cell id, and the bus stamps
   * interleaved deltas in arrival order.
   *
   * The child also gets a single `contact_supervisor` tool (via a child bridge
   * extension) so it can send non-blocking progress updates up to this card
   * while it works. That is the ONLY tool it has (--tools allowlist of one),
   * so it still cannot recurse into managed_subagent.
   */
  async runChildAgent(task: string, agentName?: string): Promise<string> {
    // Named delegation (native named subagents): resolve the agent's persona and
    // compose it INTO the subagent operating prompt (never replacing it — that
    // prompt carries the contact_supervisor / self-contained-result contract).
    // v1 borrows only the persona body + name; the agent's tools/model are out of
    // scope (they'd conflict with the supervisor-channel tool allowlist).
    const resolved = agentName ? this.resolveAgent?.(agentName, this.meta.projectId) : undefined;
    if (agentName && !resolved) {
      throw new Error(`unknown agent: ${agentName}`);
    }
    const persona = resolved ? `\n\n# Agent: ${agentName}\n${resolved.body}` : "";
    const cellId = `subagent-${randomUUID()}`;
    // The child's supervisor bridge (server-provided): a distinct bridge session
    // id whose contact_supervisor calls route back to THIS card. undefined when
    // no channel is available — the child then runs tool-less (--no-tools).
    const childSessionId = randomUUID();
    const childBridge = this.childBridgeFactory?.(childSessionId, {
      parentSessionId: this.meta.id,
      cellId,
    });
    // Outermost try/finally disposes the child bridge no matter what — even if
    // the mkdtempSync below throws before the inner (prompt-dir) try is entered,
    // the bridge token/route/temp dir would otherwise leak.
    try {
      // The child system prompt is multi-line, so route it through a temp file —
      // a multi-line --system-prompt literal is truncated by cmd.exe on Windows.
      const promptDir = mkdtempSync(join(tmpdir(), "agent-deck-subagent-"));
      // Inner try/finally removes the prompt dir even if building the child
      // (writeFileSync / resolvePiBinary / new PiSession) throws before it exists.
      try {
        const promptFile = join(promptDir, "system.md");
        writeFileSync(promptFile, `${SUBAGENT_SYSTEM_PROMPT}${persona}\n\nTask:\n${task}`);

        const child = new PiSession({
          binPath: resolvePiBinary().path,
          args: buildLaunchArgs({
            kind: "agent",
            systemPrompt: { mode: "replace", text: promptFile },
            // With a supervisor channel the child's ONLY tool is contact_supervisor
            // (an allowlist of one — verified against real pi that an extension tool
            // is callable this way while --no-tools would strip it). Without a
            // channel it runs tool-less. Either way it can't reach managed_subagent.
            tools: childBridge ? ["contact_supervisor"] : [],
            provider: this.helperContext?.provider,
            model: this.helperContext?.model,
            // Provider-registration extensions (ambient discovery disabled), plus
            // the child bridge that carries contact_supervisor.
            extensions: childBridge
              ? [...(this.helperContext?.extensions ?? []), childBridge.extension]
              : this.helperContext?.extensions,
          }),
          cwd: this.meta.cwd,
          env: this.helperContext?.env,
          requestTimeoutMs: SUBAGENT_TIMEOUT_MS,
        });
        // Open the Subagent card in the PARENT transcript before the child runs.
        this.emitDomain({
          type: "cell_open",
          cell: {
            kind: "subagent",
            id: cellId,
            task,
            status: "running",
            text: "",
            progress: [],
            ...(agentName ? { agentName } : {}),
          },
        });
        const startedAt = Date.now();
        let streamed = "";
        // Run metadata captured from the child's assistant turns (native
        // PiSubagentRunRecord parity): the model it used + token usage ACCUMULATED
        // across turns (a contact_supervisor round-trip produces two assistant
        // turns, and the run's total token cost is their sum).
        let childModel: string | undefined;
        let childInputTokens = 0;
        let childOutputTokens = 0;
        let sawUsage = false;
        const metadata = (): {
          model?: string;
          inputTokens?: number;
          outputTokens?: number;
          durationMs: number;
        } => ({
          model: childModel,
          inputTokens: sawUsage ? childInputTokens : undefined,
          outputTokens: sawUsage ? childOutputTokens : undefined,
          durationMs: Date.now() - startedAt,
        });
        try {
          const idle = new Promise<void>((resolve, reject) => {
            const timer = setTimeout(
              () => reject(new Error("subagent timeout")),
              SUBAGENT_TIMEOUT_MS,
            );
            timer.unref();
            child.on("event", (event) => {
              // Forward the child's assistant text into the parent card as it
              // streams (best-effort visual; cell_final below is authoritative).
              const e = event as {
                type?: string;
                message?: {
                  role?: string;
                  model?: unknown;
                  usage?: { input?: number; output?: number };
                };
                assistantMessageEvent?: { type?: string; delta?: string };
              };
              if (
                e.type === "message_update" &&
                e.assistantMessageEvent?.type === "text_delta" &&
                typeof e.assistantMessageEvent.delta === "string"
              ) {
                streamed += e.assistantMessageEvent.delta;
                this.emitDomain({
                  type: "subagent_delta",
                  cellId,
                  delta: e.assistantMessageEvent.delta,
                });
              }
              // Capture model + token usage from each of the child's assistant
              // turns; accumulate tokens so a tool round-trip counts every turn.
              if (e.type === "message_end" && e.message?.role === "assistant") {
                if (typeof e.message.model === "string") childModel = e.message.model;
                if (e.message.usage) {
                  if (typeof e.message.usage.input === "number") {
                    childInputTokens += e.message.usage.input;
                  }
                  if (typeof e.message.usage.output === "number") {
                    childOutputTokens += e.message.usage.output;
                  }
                  sawUsage = true;
                }
              }
              if (e.type === "agent_end") {
                clearTimeout(timer);
                resolve();
              }
            });
            child.on("exit", () => reject(new Error("subagent exited before finishing")));
          });
          idle.catch(() => {});
          child.start();
          await child.prompt(task);
          await idle;
          const { text } = await child.request({ type: "get_last_assistant_text" });
          const finalText = text ?? streamed;
          this.emitDomain({
            type: "cell_final",
            cell: {
              kind: "subagent",
              id: cellId,
              task,
              status: "done",
              text: finalText,
              progress: [],
              ...(agentName ? { agentName } : {}),
              ...metadata(),
            },
          });
          return finalText;
        } catch (error) {
          // Mark the card failed (preserving whatever streamed) and re-throw so the
          // bridge tool still renders the failure in its result.
          this.emitDomain({
            type: "cell_final",
            cell: {
              kind: "subagent",
              id: cellId,
              task,
              status: "error",
              text: streamed,
              progress: [],
              ...(agentName ? { agentName } : {}),
              ...metadata(),
            },
          });
          throw error;
        } finally {
          await child.stop();
        }
      } finally {
        // Remove the prompt temp dir once the child has exited (best-effort).
        try {
          rmSync(promptDir, { recursive: true, force: true });
        } catch {
          // Best-effort.
        }
      }
    } finally {
      // Tear down the child bridge (token + supervisor route + temp dir) — runs
      // even if mkdtempSync above threw before the inner try was entered.
      childBridge?.dispose();
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
          this.emitDomain(domainEvent);
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
    this.emitDomain({ type: "question_answered", cellId: `question-${id}` });
  }

  async getCommands(): Promise<Awaited<ReturnType<PiSession["getCommands"]>>> {
    return await this.pi.getCommands();
  }

  async getState(): Promise<Awaited<ReturnType<PiSession["getState"]>>> {
    return await this.pi.getState();
  }

  async getSessionStats(): Promise<Awaited<ReturnType<PiSession["getSessionStats"]>>> {
    return await this.pi.getSessionStats();
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
     * Threaded to each ManagedSession so runChildAgent can give its children a
     * supervisor channel routed back to the right transcript cell.
     */
    private readonly childBridgeFactory?: ChildBridgeFactory,
    /** Resolves a named agent for `managed_subagent{agent}` delegation, threaded
     * to each ManagedSession. */
    private readonly resolveAgent?: AgentResolver,
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
      // The activity plan is app state (not in pi's session file), so restore it
      // from the persisted meta after the pi history is rebuilt.
      if (revived.plan && revived.plan.length > 0) session.restorePlan(revived.plan);
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
    // Until a ManagedSession is constructed (it owns tempDirs cleanup via the
    // pi-exit handler), a throw here would leak the generated temp dirs — clean
    // them up on any pre-construction failure.
    let owned = false;
    try {
      return this.launchWithTemp(meta, plan, env, options, tempDirs, () => {
        owned = true;
      });
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

  private launchWithTemp(
    meta: SessionMeta,
    plan: LaunchPlan,
    env: Record<string, string | undefined> | undefined,
    options: { holdLive?: boolean } | undefined,
    tempDirs: string[],
    markOwned: () => void,
  ): ManagedSession {
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
    // Agent-backed sessions pass the agent body as a --system-prompt /
    // --append-system-prompt value. A MULTI-LINE literal is truncated on Windows
    // (pi runs via a pi.cmd shim through cmd.exe, which cuts an argument at the
    // first newline) — the same bug the memory block hit. pi reads a value that
    // is an existing file path as a file, so route a multi-line agent body
    // through a temp file (single-line bodies stay literal). The temp dir is
    // cleaned up with the others on exit.
    if (launchPlan.kind === "agent" && launchPlan.systemPrompt.text.includes("\n")) {
      const dir = mkdtempSync(join(tmpdir(), "agent-deck-agent-prompt-"));
      // Track before the write so a writeFileSync failure still cleans up the dir.
      tempDirs.push(dir);
      const file = join(dir, "system.md");
      writeFileSync(file, launchPlan.systemPrompt.text);
      launchPlan = {
        ...launchPlan,
        systemPrompt: { ...launchPlan.systemPrompt, text: file },
      };
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
      this.childBridgeFactory,
      this.resolveAgent,
    );
    // ManagedSession now owns tempDirs cleanup (on pi exit); no leak past here.
    markOwned();
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
    const session = this.launch(meta, plan, env, { holdLive: true });
    await session.seedFromHistory();
    if (meta.plan && meta.plan.length > 0) session.restorePlan(meta.plan);
    this.onMetaChange(meta);
    return session;
  }

  async stopAll(): Promise<void> {
    await Promise.all([...this.sessions.values()].map((session) => session.stop()));
  }
}
