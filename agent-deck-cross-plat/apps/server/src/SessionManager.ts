import { randomUUID } from "node:crypto";
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
  exit: PiProcessExit | null = null;

  constructor(
    readonly meta: SessionMeta,
    private readonly pi: PiSession,
    private readonly receipts: ReceiptBus,
    private readonly onMetaChange: (meta: SessionMeta) => void = () => {},
  ) {
    pi.on("event", (piEvent) => {
      for (const domainEvent of ingestPiEvent(this.ingest, piEvent)) {
        this.transcript = reduceTranscript(this.transcript, domainEvent);
        this.bus.append(domainEvent);
        if (domainEvent.type === "cell_delta" && !this.sawFirstDelta) {
          this.sawFirstDelta = true;
          receipts.emit("first_delta", meta.id);
        }
        if (domainEvent.type === "cell_final" && domainEvent.cell.kind === "assistant") {
          receipts.emit("assistant_final", meta.id);
        }
        if (domainEvent.type === "agent_status" && domainEvent.status === "idle") {
          receipts.emit("idle", meta.id);
          this.captureSessionFile();
        }
      }
    });
    pi.on("exit", (exit) => {
      this.exit = exit;
      this.meta.endedAt = new Date().toISOString();
      this.onMetaChange(this.meta);
    });
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

  snapshot(): { seq: number; state: TranscriptState } {
    return { seq: this.bus.lastSeq, state: this.transcript };
  }

  get isRunning(): boolean {
    return this.pi.isRunning;
  }

  async prompt(message: string): Promise<void> {
    await this.pi.prompt(message);
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

  respondToUiRequest(response: Record<string, unknown>): void {
    this.pi.respondToUiRequest(response as Parameters<PiSession["respondToUiRequest"]>[0]);
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

  async stop(): Promise<void> {
    await this.pi.stop();
  }
}

export class SessionManager {
  private readonly sessions = new Map<string, ManagedSession>();

  constructor(
    private readonly receipts: ReceiptBus,
    private readonly onMetaChange: (meta: SessionMeta) => void = () => {},
  ) {}

  create(options: CreateSessionOptions): ManagedSession {
    const id = randomUUID();
    const meta: SessionMeta = {
      id,
      cwd: options.cwd,
      createdAt: new Date().toISOString(),
      projectId: options.projectId,
      agentName: options.agentName,
    };
    const pi = new PiSession({
      binPath: resolvePiBinary().path,
      args: buildLaunchArgs(options.plan),
      cwd: options.cwd,
      env: options.env,
    });
    const session = new ManagedSession(meta, pi, this.receipts, this.onMetaChange);
    this.sessions.set(id, session);
    pi.start();
    this.receipts.emit("session_created", id);
    return session;
  }

  get(id: string): ManagedSession | undefined {
    return this.sessions.get(id);
  }

  list(): SessionMeta[] {
    return [...this.sessions.values()].map((session) => session.meta);
  }

  async stopAll(): Promise<void> {
    await Promise.all([...this.sessions.values()].map((session) => session.stop()));
  }
}
