import { Schema } from "effect";

/**
 * Checkpoints wire contract (Slice 18a — CAPTURE + list, server-only). A
 * checkpoint of turn N is the pair {conversation snapshot, workspace snapshot}
 * captured at the idle turn-boundary (see docs/checkpoints-design.md): pi's
 * session file copied wholesale + the working tree captured as a HIDDEN git ref.
 * This surface is the READ side only — `checkpoints_list` — riding
 * `RpcClientFrame` alongside the diff/terminal/file op families. Rollback and the
 * timeline UI are Slice 18b; capture is landable on its own because it is inert
 * until something restores.
 *
 * Design notes:
 *   - `CheckpointInfo` is the CLIENT-facing projection of a checkpoint record:
 *     the per-turn index, when it was captured, a short human label (the turn's
 *     first user message), and whether the workspace half was captured
 *     (`hasFiles: false` for a non-git session — the checkpoint then carries only
 *     the conversation snapshot). The on-disk record (server-internal:
 *     snapshot path, git ref, cwd, source-file identity) never crosses the wire.
 *   - The retained list is bounded server-side to {@link CHECKPOINT_MAX_RETAINED}
 *     per session (oldest pruned first); the wire list is capped to match.
 */

/** Cap on retained checkpoints per session — oldest snapshot file + git ref are
 * pruned beyond it (server policy; the wire list is bounded to the same count). */
export const CHECKPOINT_MAX_RETAINED = 50;

/** Cap (in characters) of a checkpoint's human label on the wire. */
export const CHECKPOINT_LABEL_MAX_CHARS = 200;

/** Integer with `Number.isInteger` semantics (`WireInt` parity — see protocol.ts). */
const wireInt = (description: string) =>
  Schema.Number.pipe(
    Schema.filter((n) => (Number.isInteger(n) && n >= 0) || "must be a non-negative integer", {
      identifier: "CheckpointWireInt",
      description,
    }),
  );

/**
 * One checkpoint as the client sees it. `turnIndex` is the monotonic per-session
 * capture index (0-based, in capture order); `createdAt` is an ISO timestamp;
 * `label` is a short summary of the turn (its first user message, bounded);
 * `hasFiles` is true when the workspace half (a hidden git ref) was captured —
 * false for a non-git session (conversation snapshot only).
 */
export const CheckpointInfo = Schema.Struct({
  turnIndex: wireInt("the per-session capture index"),
  createdAt: Schema.String,
  label: Schema.String.pipe(Schema.maxLength(CHECKPOINT_LABEL_MAX_CHARS)),
  hasFiles: Schema.Boolean,
});
export type CheckpointInfo = typeof CheckpointInfo.Type;

// ---------------------------------------------------------------------------
// Client → server checkpoint requests (ride RpcClientFrame alongside ClientMessage)
// ---------------------------------------------------------------------------

export const CheckpointClientRequest = Schema.Union(
  Schema.Struct({
    /** List a session's captured checkpoints (newest capture last). */
    type: Schema.Literal("checkpoints_list"),
    sessionId: Schema.String,
  }),
);
export type CheckpointClientRequest = typeof CheckpointClientRequest.Type;
