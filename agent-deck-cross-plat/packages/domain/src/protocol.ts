/**
 * WebSocket wire contract.
 *
 * The wire CONTRACT TYPES live in `@agent-deck/contracts` (Effect Schema, the
 * single source of truth) and are re-exported here so the existing
 * `@agent-deck/domain` importers keep resolving the same names — the type source
 * moved, not the byte format. This is a **type-only** re-export, so it creates no
 * runtime dependency edge: contracts imports domain's `DomainEvent` /
 * `TranscriptState` type-only in return, and the whole domain⇄contracts cycle
 * lives purely in the type graph (erased at build).
 *
 * The runtime validator at the socket boundary is the contracts Effect Schema
 * (`RpcClientFrame` on the `/rpc` path). The legacy zod `clientMessageSchema`
 * that once validated the retired `/ws` envelope was deleted in Slice 7c.
 * `SessionPlanItem` / `PlanItemStatus` are still owned by `./transcript.ts`, and
 * `ThinkingLevel` by `./thinking.ts` — re-exporting them from contracts would
 * collide, so they are deliberately not re-exported here.
 */
export type {
  ClientMessage,
  ProjectType,
  DiscoveredProject,
  ProjectMeta,
  SessionMeta,
  ServerMessage,
} from "@agent-deck/contracts";
