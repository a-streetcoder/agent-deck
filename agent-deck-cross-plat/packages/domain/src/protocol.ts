import { z } from "zod";
import type { DomainEvent, TranscriptState } from "./transcript.ts";

/**
 * WebSocket wire contract. Client→server messages are zod-validated at the
 * socket boundary; server→client messages are typed (the client trusts its own
 * server). REST request bodies live next to their routes and also use zod.
 */

export const clientMessageSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("hello") }),
  z.object({
    type: z.literal("subscribe_session"),
    sessionId: z.string(),
    /** Last seq this client saw; omit for a fresh snapshot. */
    lastSeq: z.number().int().nonnegative().optional(),
  }),
  z.object({ type: z.literal("prompt"), sessionId: z.string(), message: z.string() }),
  z.object({ type: z.literal("steer"), sessionId: z.string(), message: z.string() }),
  z.object({ type: z.literal("follow_up"), sessionId: z.string(), message: z.string() }),
  z.object({ type: z.literal("abort"), sessionId: z.string() }),
  z.object({
    type: z.literal("ui_response"),
    sessionId: z.string(),
    /** Raw pi extension_ui_response payload (pass-through). */
    response: z.record(z.unknown()),
  }),
]);

export type ClientMessage = z.infer<typeof clientMessageSchema>;

export interface ProjectMeta {
  id: string;
  /** Absolute path to the project root; sessions run with this as cwd. */
  path: string;
  name: string;
  createdAt: string;
  /** Skill names injected (as --skill paths) into this project's parent sessions. */
  assignedSkills?: string[];
  /** Agent preselected when switching to this project. */
  defaultAgentName?: string;
}

export interface SessionMeta {
  id: string;
  cwd: string;
  createdAt: string;
  projectId?: string;
  /** Set when the session is backed by a named agent (injected system prompt). */
  agentName?: string;
  title?: string;
  /** pi's canonical session file — the resume handle. Captured after first turn. */
  piSessionFile?: string;
  /** Set when the pi subprocess exits; absent while live. */
  endedAt?: string;
  /**
   * The LaunchPlan this session was created with (opaque here — typed in
   * pi-host). Persisted so resume relaunches with the same shape: agent
   * system prompt/tools/skills, project assignments, provider/model.
   */
  launchPlan?: unknown;
}

export type ServerMessage =
  | { type: "hello_ok"; sessions: SessionMeta[] }
  | { type: "event"; sessionId: string; seq: number; event: DomainEvent }
  | { type: "snapshot"; sessionId: string; seq: number; state: TranscriptState }
  | { type: "session_exit"; sessionId: string; code: number | null; signal: string | null }
  | { type: "session_meta"; session: SessionMeta }
  | { type: "resources_changed" }
  | { type: "error"; message: string; sessionId?: string };
