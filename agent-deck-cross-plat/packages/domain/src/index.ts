// Pure domain layer: entities, transcript reducer, pi-event ingestion, wire types.
// No runtime deps are imported in code anymore — the wire validator is the
// contracts Effect Schema (the legacy zod `clientMessageSchema` was deleted in
// Slice 7c; the residual `zod` manifest entry is now dead, safe to drop later).
// Pi types are imported type-only from the pinned package.
export * from "./pi-types.ts";
export * from "./transcript.ts";
export * from "./thinking.ts";
export * from "./ingest.ts";
export * from "./protocol.ts";
export * from "./resources.ts";
export * from "./memory.ts";
export * from "./extensions.ts";
export * from "./loops.ts";
