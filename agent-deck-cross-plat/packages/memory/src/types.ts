/**
 * Agent Deck Memory — durable, project-scoped knowledge stored as inspectable
 * Markdown (see agent-deck-documentation/memory.md). This package is the
 * cross-platform store: creation, retrieval, and the write guards. The native
 * app's on-device NLContextualEmbedding recall is macOS-only, so retrieval
 * starts lexical (term-overlap over title/summary/tags) — the same corrective
 * signal the native app blends in — with a JS on-device embedder to follow.
 */

/** Durable fact about project structure, architecture, conventions, deps. */
export type MemoryType = "context" | "decision" | "runbook" | "failure" | "preference";

/**
 * active/pinned are injected and searchable; stale is inspectable but not
 * injected; archived is hidden from normal recall.
 */
export type MemoryStatus = "active" | "pinned" | "stale" | "archived";

export const MEMORY_TYPES: readonly MemoryType[] = [
  "context",
  "decision",
  "runbook",
  "failure",
  "preference",
];

export const MEMORY_STATUSES: readonly MemoryStatus[] = ["active", "pinned", "stale", "archived"];

/** A single memory: YAML frontmatter fields plus the Markdown body. */
export interface MemoryRecord {
  id: string;
  type: MemoryType;
  /** Only project scope exists — there is no global memory. */
  scope: "project";
  status: MemoryStatus;
  title: string;
  /** A retrieval key: the words a future question about the topic would use. */
  summary: string;
  body: string;
  createdAt: string;
  updatedAt: string;
  tags: string[];
  /** Why the memory was written (audit; never injected). */
  writeReason?: string;
  /** The subagent that wrote it, if any. */
  sourceAgentName?: string;
}

/** Fields an agent supplies to write a memory (id present = update in place). */
export interface MemoryWriteInput {
  id?: string;
  type: MemoryType;
  title: string;
  summary: string;
  body: string;
  tags?: string[];
  status?: Extract<MemoryStatus, "active" | "pinned">;
  writeReason?: string;
  sourceAgentName?: string;
  /** Override the near-duplicate guard when the fact is genuinely distinct. */
  confirmNew?: boolean;
}

/** Outcome of a write attempt. */
export type MemoryWriteResult =
  | { ok: true; record: MemoryRecord; created: boolean }
  | { ok: false; reason: "duplicate"; existing: MemoryRecord; message: string }
  | { ok: false; reason: "secret"; message: string }
  | { ok: false; reason: "not_found"; message: string }
  | { ok: false; reason: "no_project"; message: string };

/** A ranked search hit. */
export interface MemorySearchHit {
  record: MemoryRecord;
  score: number;
  /** Informative terms the query shared with the memory (the lexical evidence). */
  sharedTerms: string[];
}
