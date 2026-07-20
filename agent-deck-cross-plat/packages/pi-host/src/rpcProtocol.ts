import type {
  RpcEventListener,
  RpcExtensionUIRequest,
  RpcResponse,
} from "@earendil-works/pi-coding-agent";

/**
 * The pieces of pi's JSONL RPC wire protocol that every host-side consumer
 * needs and that must never drift apart: stdout line classification, request
 * id allocation, and the shared timeout constants.
 *
 * Two correlation layers sit on top of PiProcess — the portable callback
 * `PiSession` (this package) and the server's Effect service
 * (apps/server/src/services/piHost.ts). Both used to hand-roll the same
 * parse → malformed | response | event decision tree; this module is the ONE
 * place that tree lives now. Pure functions only: no I/O, no Effect, no
 * EventEmitter — both consumers stay free to bridge it into their own world.
 */

/** pi's streaming event union, derived from the exported listener type. */
export type PiAgentEvent = Parameters<RpcEventListener>[0];

/** Everything pi pushes that is not a command response. */
export type PiInboundEvent = PiAgentEvent | RpcExtensionUIRequest;

export type PiRpcResponse = RpcResponse;

/** A response that can be correlated: it names the request it answers. */
export type PiAddressedResponse = PiRpcResponse & { readonly id: string };

/** Default timeout for request/response commands (0 disables). */
export const DEFAULT_REQUEST_TIMEOUT_MS = 20_000;

/**
 * Manual compaction blocks on an LLM call (pi summarizes older history), so
 * it gets a generous timeout instead of the fast ack path of prompt/steer.
 */
export const COMPACT_TIMEOUT_MS = 120_000;

/**
 * What one stdout line means to a correlation layer:
 *  - `ignored`   — nothing to do: a blank line, or a response that names no
 *    request id (the legacy silent-drop rule — such a response can never be
 *    correlated, and it is NOT malformed: pi produced valid JSON).
 *  - `malformed` — not JSON, or JSON that is not a `{ type: ... }` record.
 *    Surfaced to consumers, never thrown (legacy parity).
 *  - `response`  — an addressed command response for the pending-request map.
 *  - `event`     — everything else pi pushes, fanned out in stdout order.
 */
export type PiClassifiedLine =
  | { readonly kind: "ignored"; readonly reason: "blank" | "response-without-id" }
  | { readonly kind: "malformed"; readonly line: string }
  | { readonly kind: "response"; readonly response: PiAddressedResponse }
  | { readonly kind: "event"; readonly event: PiInboundEvent };

/** Classify one JSONL stdout line. Pure; identical rules for every consumer. */
export function classifyPiLine(line: string): PiClassifiedLine {
  if (line.trim().length === 0) return { kind: "ignored", reason: "blank" };
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    return { kind: "malformed", line };
  }
  if (typeof parsed !== "object" || parsed === null || !("type" in parsed)) {
    return { kind: "malformed", line };
  }
  if ((parsed as { type: unknown }).type === "response") {
    const response = parsed as PiRpcResponse;
    if (!response.id) return { kind: "ignored", reason: "response-without-id" };
    return { kind: "response", response: response as PiAddressedResponse };
  }
  return { kind: "event", event: parsed as PiInboundEvent };
}

/**
 * A per-connection allocator for the `req-N` command ids both correlation
 * layers key their pending maps on. One source per pi process — ids are only
 * unique within it.
 */
export function createRequestIdSource(): () => string {
  let next = 0;
  return () => `req-${next++}`;
}
