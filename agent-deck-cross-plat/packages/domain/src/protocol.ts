import { z } from "zod";
import type { DomainEvent, SessionPlanItem, TranscriptState } from "./transcript.ts";

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
  z.object({
    type: z.literal("prompt"),
    sessionId: z.string(),
    message: z.string(),
    /** Base64 image attachments sent with the prompt (pi ImageContent). */
    images: z
      .array(
        z.object({
          type: z.literal("image"),
          data: z.string().max(20_000_000),
          mimeType: z.string().max(100),
        }),
      )
      .max(8)
      .optional(),
  }),
  z.object({ type: z.literal("steer"), sessionId: z.string(), message: z.string() }),
  z.object({ type: z.literal("follow_up"), sessionId: z.string(), message: z.string() }),
  z.object({ type: z.literal("abort"), sessionId: z.string() }),
  z.object({ type: z.literal("compact"), sessionId: z.string() }),
  z.object({
    type: z.literal("set_model"),
    sessionId: z.string(),
    provider: z.string().min(1).max(200),
    modelId: z.string().min(1).max(200),
  }),
  z.object({
    type: z.literal("set_thinking"),
    sessionId: z.string(),
    level: z.enum(["off", "minimal", "low", "medium", "high", "xhigh"]),
  }),
  z.object({
    type: z.literal("ui_response"),
    sessionId: z.string(),
    /** Raw pi extension_ui_response payload (pass-through). */
    response: z.record(z.unknown()),
  }),
]);

export type ClientMessage = z.infer<typeof clientMessageSchema>;

export type ProjectType =
  | "xcode"
  | "swift"
  | "tauri"
  | "electron"
  | "nextjs"
  | "nuxt"
  | "astro"
  | "sveltekit"
  | "angular"
  | "vue"
  | "react"
  | "node"
  | "go"
  | "rust"
  | "python"
  | "ruby"
  | "git"
  | "unknown";

/** A project candidate found by scanning a configured root folder. */
export interface DiscoveredProject {
  path: string;
  name: string;
  type: ProjectType;
  /** Already in the registry (visible or hidden). */
  registered: boolean;
}

export interface ProjectMeta {
  id: string;
  /** Absolute path to the project root; sessions run with this as cwd. */
  path: string;
  name: string;
  type?: ProjectType;
  createdAt: string;
  /** Skill names injected (as --skill paths) into this project's parent sessions. */
  assignedSkills?: string[];
  /**
   * Prompt-template names made available (as --prompt-template paths) in this
   * project's parent sessions — native assignedPromptTemplateNames, unioned with
   * the app-level defaultPromptTemplates at launch.
   */
  assignedPrompts?: string[];
  /** Agent preselected when switching to this project. */
  defaultAgentName?: string;
  /** Disabled projects are hidden from the sidebar and session creation. */
  enabled?: boolean;
  /**
   * "Hide from list": the entry disappears everywhere but its metadata
   * (assignments, default agent, session links) is preserved; re-adding the
   * same path un-hides it.
   */
  hidden?: boolean;
}

export interface SessionMeta {
  id: string;
  cwd: string;
  createdAt: string;
  /** Last-touched time (created / resumed / prompted / titled). Drives the
   * session list's most-recently-active-first ordering. Optional: sessions
   * persisted before this field fall back to createdAt. */
  updatedAt?: string;
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
  /**
   * The session's activity plan (set_session_plan / update_session_plan),
   * persisted so a resumed session restores it — the plan is app state, not part
   * of pi's session file. Absent until a plan is set.
   */
  plan?: SessionPlanItem[];
  /**
   * Git worktree isolation (native piAgentSessionsUseWorktree). When the setting
   * is on and the project is a git repo, the session runs in its own worktree on
   * branch `agent-deck/session-<id>` (cwd = worktreePath) so its work never
   * touches the main checkout; the Merge action brings it back. Absent when the
   * session runs in the project root.
   */
  worktreePath?: string;
  worktreeBranch?: string;
  worktreeSourceBranch?: string;
}

export type ServerMessage =
  | { type: "hello_ok"; sessions: SessionMeta[] }
  | { type: "event"; sessionId: string; seq: number; event: DomainEvent }
  | { type: "snapshot"; sessionId: string; seq: number; state: TranscriptState }
  | { type: "session_exit"; sessionId: string; code: number | null; signal: string | null }
  | { type: "session_meta"; session: SessionMeta }
  | { type: "session_removed"; sessionId: string }
  | { type: "resources_changed" }
  | { type: "error"; message: string; sessionId?: string };
