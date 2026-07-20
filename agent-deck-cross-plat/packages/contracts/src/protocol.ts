import { Schema } from "effect";
import type { DomainEvent, TranscriptState } from "@agent-deck/domain";

/**
 * Effect Schema definition of the WebSocket wire contract, and — as of Slice 7 —
 * the single SOURCE OF TRUTH for the wire types: `@agent-deck/domain`'s
 * `protocol.ts` now re-exports these types (a type-only re-export, so no runtime
 * cycle). The wire format is IDENTICAL to the legacy zod schema that still lives
 * in domain for the legacy `/ws` envelope; a golden-fixture parity test
 * (test/protocol-parity.test.ts) asserts both validators accept/reject the same
 * corpus.
 *
 * Structs are wrapped in `Schema.mutable` (and arrays/records too) so the derived
 * types have writable fields — the server mutates `SessionMeta`/`ProjectMeta` in
 * place (e.g. `meta.updatedAt = …`), and this keeps the re-exported domain types
 * assignable at every existing callsite.
 */

// ---------------------------------------------------------------------------
// Client → server messages (runtime-validated at the socket boundary)
// ---------------------------------------------------------------------------

/** Base64 image attachment sent with a prompt (pi ImageContent). */
export const ImageAttachment = Schema.Struct({
  type: Schema.Literal("image"),
  data: Schema.String.pipe(Schema.maxLength(20_000_000)),
  mimeType: Schema.String.pipe(Schema.maxLength(100)),
});
export type ImageAttachment = typeof ImageAttachment.Type;

export const ThinkingLevel = Schema.Literal("off", "minimal", "low", "medium", "high", "xhigh");
export type ThinkingLevel = typeof ThinkingLevel.Type;

/**
 * Integer with zod `.int()` semantics (`Number.isInteger`), NOT Effect's
 * `Schema.int()` (`Number.isSafeInteger`). The difference matters for wire
 * parity: JSON-representable unsafe integers (e.g. 2^53 = 9007199254740992,
 * 1e21) pass the zod boundary today, so the Effect port must accept them too.
 * Pinned by the magnitude fixtures in test/protocol-parity.test.ts.
 */
const WireInt = Schema.Number.pipe(
  Schema.filter((n) => Number.isInteger(n) || "must be an integer", {
    identifier: "WireInt",
    description: "an integer (Number.isInteger — zod .int() parity)",
  }),
);

/**
 * A plain JSON object record (`{ [key: string]: unknown }`), the runtime shape
 * of a pass-through pi payload.
 *
 * Effect's bare `Schema.Record` accepts any `object` and, worse, *coerces* exotic
 * objects: a `Date`/`Map` has no own enumerable string keys, so `Record` decodes
 * it to an empty `{}` and passes — the Slice-1 known nuance ("Effect Record
 * accepts exotic objects that zod rejected"). Now that this schema is the runtime
 * validator at the RPC boundary (Slice 7), we refine on the RAW input instead:
 * the decoded value must be a genuine plain object (prototype `Object.prototype`
 * or `null`), which rejects arrays, `Date`, `Map`, and every other exotic — while
 * accepting the only thing the wire ever actually carries, JSON objects. Declared
 * as a guard so the value passes through untouched (no key coercion).
 */
export const PlainJsonRecord: Schema.Schema<Record<string, unknown>> = Schema.declare(
  (input: unknown): input is Record<string, unknown> => {
    if (typeof input !== "object" || input === null) return false;
    const proto: unknown = Object.getPrototypeOf(input);
    return proto === Object.prototype || proto === null;
  },
  {
    identifier: "PlainJsonRecord",
    description: "a plain JSON object (rejects arrays, Date, Map, and other exotics)",
  },
);

export const ClientMessage = Schema.Union(
  Schema.Struct({ type: Schema.Literal("hello") }),
  Schema.Struct({
    type: Schema.Literal("subscribe_session"),
    sessionId: Schema.String,
    /** Last seq this client saw; omit for a fresh snapshot. */
    lastSeq: Schema.optional(WireInt.pipe(Schema.nonNegative())),
  }),
  Schema.Struct({
    type: Schema.Literal("prompt"),
    sessionId: Schema.String,
    message: Schema.String,
    /** Base64 image attachments sent with the prompt (pi ImageContent). */
    images: Schema.optional(Schema.mutable(Schema.Array(ImageAttachment)).pipe(Schema.maxItems(8))),
  }),
  Schema.Struct({
    type: Schema.Literal("steer"),
    sessionId: Schema.String,
    message: Schema.String,
  }),
  Schema.Struct({
    type: Schema.Literal("follow_up"),
    sessionId: Schema.String,
    message: Schema.String,
  }),
  Schema.Struct({ type: Schema.Literal("abort"), sessionId: Schema.String }),
  Schema.Struct({ type: Schema.Literal("compact"), sessionId: Schema.String }),
  Schema.Struct({
    type: Schema.Literal("set_model"),
    sessionId: Schema.String,
    provider: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(200)),
    modelId: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(200)),
  }),
  Schema.Struct({
    type: Schema.Literal("set_thinking"),
    sessionId: Schema.String,
    level: ThinkingLevel,
  }),
  Schema.Struct({
    type: Schema.Literal("ui_response"),
    sessionId: Schema.String,
    /** Raw pi extension_ui_response payload (pass-through, plain-object only). */
    response: PlainJsonRecord,
  }),
);
export type ClientMessage = typeof ClientMessage.Type;

// ---------------------------------------------------------------------------
// Shared metadata shapes
// ---------------------------------------------------------------------------

export const ProjectType = Schema.Literal(
  "xcode",
  "swift",
  "tauri",
  "electron",
  "nextjs",
  "nuxt",
  "astro",
  "sveltekit",
  "angular",
  "vue",
  "react",
  "node",
  "go",
  "rust",
  "python",
  "ruby",
  "git",
  "unknown",
);
export type ProjectType = typeof ProjectType.Type;

/** A project candidate found by scanning a configured root folder. */
export const DiscoveredProject = Schema.mutable(
  Schema.Struct({
    path: Schema.String,
    name: Schema.String,
    type: ProjectType,
    /** Already in the registry (visible or hidden). */
    registered: Schema.Boolean,
  }),
);
export type DiscoveredProject = typeof DiscoveredProject.Type;

export const ProjectMeta = Schema.mutable(
  Schema.Struct({
    id: Schema.String,
    /** Absolute path to the project root; sessions run with this as cwd. */
    path: Schema.String,
    name: Schema.String,
    type: Schema.optional(ProjectType),
    createdAt: Schema.String,
    /** Skill names injected (as --skill paths) into this project's parent sessions. */
    assignedSkills: Schema.optional(Schema.mutable(Schema.Array(Schema.String))),
    /**
     * Prompt-template names made available (as --prompt-template paths) in this
     * project's parent sessions — native assignedPromptTemplateNames, unioned with
     * the app-level defaultPromptTemplates at launch.
     */
    assignedPrompts: Schema.optional(Schema.mutable(Schema.Array(Schema.String))),
    /** Agent preselected when switching to this project. */
    defaultAgentName: Schema.optional(Schema.String),
    /** Disabled projects are hidden from the sidebar and session creation. */
    enabled: Schema.optional(Schema.Boolean),
    /**
     * "Hide from list": the entry disappears everywhere but its metadata
     * (assignments, default agent, session links) is preserved; re-adding the
     * same path un-hides it.
     */
    hidden: Schema.optional(Schema.Boolean),
  }),
);
export type ProjectMeta = typeof ProjectMeta.Type;

export const PlanItemStatus = Schema.Literal("todo", "in_progress", "done", "blocked", "skipped");
export type PlanItemStatus = typeof PlanItemStatus.Type;

export const SessionPlanItem = Schema.mutable(
  Schema.Struct({
    id: Schema.String,
    title: Schema.String,
    status: PlanItemStatus,
  }),
);
export type SessionPlanItem = typeof SessionPlanItem.Type;

export const SessionMeta = Schema.mutable(
  Schema.Struct({
    id: Schema.String,
    cwd: Schema.String,
    createdAt: Schema.String,
    /** Last-touched time (created / resumed / prompted / titled). Drives the
     * session list's most-recently-active-first ordering. Optional: sessions
     * persisted before this field fall back to createdAt. */
    updatedAt: Schema.optional(Schema.String),
    projectId: Schema.optional(Schema.String),
    /** Set when the session is backed by a named agent (injected system prompt). */
    agentName: Schema.optional(Schema.String),
    title: Schema.optional(Schema.String),
    /** pi's canonical session file — the resume handle. Captured after first turn. */
    piSessionFile: Schema.optional(Schema.String),
    /** Set when the pi subprocess exits; absent while live. */
    endedAt: Schema.optional(Schema.String),
    /**
     * The LaunchPlan this session was created with (opaque here — typed in
     * pi-host). Persisted so resume relaunches with the same shape: agent
     * system prompt/tools/skills, project assignments, provider/model.
     */
    launchPlan: Schema.optional(Schema.Unknown),
    /**
     * The session's activity plan (set_session_plan / update_session_plan),
     * persisted so a resumed session restores it — the plan is app state, not part
     * of pi's session file. Absent until a plan is set.
     */
    plan: Schema.optional(Schema.mutable(Schema.Array(SessionPlanItem))),
    /**
     * Git worktree isolation (native piAgentSessionsUseWorktree). When the setting
     * is on and the project is a git repo, the session runs in its own worktree on
     * branch `agent-deck/session-<id>` (cwd = worktreePath) so its work never
     * touches the main checkout; the Merge action brings it back. Absent when the
     * session runs in the project root.
     */
    worktreePath: Schema.optional(Schema.String),
    worktreeBranch: Schema.optional(Schema.String),
    worktreeSourceBranch: Schema.optional(Schema.String),
  }),
);
export type SessionMeta = typeof SessionMeta.Type;

// ---------------------------------------------------------------------------
// Server → client messages (types only today — the client trusts its own
// server, so these schemas carry the shape but the event/state payloads are
// declared pass-throughs, mirroring the zod side which never validates them)
// ---------------------------------------------------------------------------

/** Domain transcript event — declared (no structural runtime validation), typed
 * against the pure reducer types in `@agent-deck/domain`. */
export const DomainEventFromSelf: Schema.Schema<DomainEvent> = Schema.declare(
  (input: unknown): input is DomainEvent => typeof input === "object" && input !== null,
  { identifier: "DomainEvent" },
);

/** Transcript snapshot state — declared pass-through, typed against domain. */
export const TranscriptStateFromSelf: Schema.Schema<TranscriptState> = Schema.declare(
  (input: unknown): input is TranscriptState => typeof input === "object" && input !== null,
  { identifier: "TranscriptState" },
);

export const ServerMessage = Schema.Union(
  Schema.Struct({
    type: Schema.Literal("hello_ok"),
    sessions: Schema.mutable(Schema.Array(SessionMeta)),
  }),
  Schema.Struct({
    type: Schema.Literal("event"),
    sessionId: Schema.String,
    seq: Schema.Number,
    event: DomainEventFromSelf,
  }),
  Schema.Struct({
    type: Schema.Literal("snapshot"),
    sessionId: Schema.String,
    seq: Schema.Number,
    state: TranscriptStateFromSelf,
  }),
  Schema.Struct({
    type: Schema.Literal("session_exit"),
    sessionId: Schema.String,
    code: Schema.NullOr(Schema.Number),
    signal: Schema.NullOr(Schema.String),
  }),
  Schema.Struct({ type: Schema.Literal("session_meta"), session: SessionMeta }),
  Schema.Struct({ type: Schema.Literal("session_removed"), sessionId: Schema.String }),
  Schema.Struct({ type: Schema.Literal("resources_changed") }),
  Schema.Struct({
    type: Schema.Literal("error"),
    message: Schema.String,
    sessionId: Schema.optional(Schema.String),
  }),
);
export type ServerMessage = typeof ServerMessage.Type;
