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

export interface SessionMeta {
  id: string;
  cwd: string;
  createdAt: string;
  title?: string;
  piSessionFile?: string;
}

export type ServerMessage =
  | { type: "hello_ok"; sessions: SessionMeta[] }
  | { type: "event"; sessionId: string; seq: number; event: DomainEvent }
  | { type: "snapshot"; sessionId: string; seq: number; state: TranscriptState }
  | { type: "session_exit"; sessionId: string; code: number | null; signal: string | null }
  | { type: "error"; message: string; sessionId?: string };
