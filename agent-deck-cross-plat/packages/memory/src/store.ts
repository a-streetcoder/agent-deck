import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { parseMemory, serializeMemory } from "./frontmatter.ts";
import { isSafeMemoryId, memoryFilePath, projectMemoryDir } from "./paths.ts";
import { scanForSecrets } from "./secrets.ts";
import { centeredCosineScores, type Embedder } from "./semantic.ts";
import {
  fuzzyMatchedTerms,
  informativeTerms,
  memoryTerms,
  overlapCoefficient,
  sharedTerms,
} from "./text.ts";
import type {
  MemoryRecord,
  MemorySearchHit,
  MemoryStatus,
  MemoryType,
  MemoryWriteInput,
  MemoryWriteResult,
} from "./types.ts";

/**
 * The project-scoped Markdown memory store. Files are the source of truth; the
 * list is derived by scanning the project's memory directory (bounded by the
 * number of memories, which is small). All timestamps are absolute ISO strings.
 */

/** Overlap coefficient at/above which a new write is held as a near-duplicate. */
const DUPLICATE_OVERLAP = 0.6;
/** A memory must share at least this many EXACT informative terms to be a hit. */
const MIN_SHARED_TERMS = 1;
/**
 * With no exact overlap, a memory needs at least this many one-edit near-misses
 * to be a hit. A LONE near-miss is too weak — one coincidental edit-distance-1
 * pair (e.g. "stale"/"scale") would otherwise surface an unrelated memory — so a
 * fuzzy-only recall requires corroboration.
 */
const MIN_FUZZY_ONLY = 2;
/** A one-edit (typo/near-miss) term match counts for less than an exact one. */
const FUZZY_WEIGHT = 0.5;
const DEFAULT_SEARCH_LIMIT = 8;
/** Cap on the injected project memory index (memory.md: 40 for parents). */
const DEFAULT_INDEX_CAP = 40;

export interface MemoryStore {
  /** App-owned base dir (e.g. <server data dir>/memory). */
  baseDir: string;
  /** The project whose memory this is; determines the storage subdir. */
  projectPath: string;
}

function slugify(title: string): string {
  const slug = title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40);
  return slug || "memory";
}

function hasProject(store: MemoryStore): boolean {
  return store.projectPath.trim().length > 0;
}

/** A collision-free id: regenerate the random suffix if a file already exists. */
function uniqueId(store: MemoryStore, type: MemoryType, title: string): string {
  const stamp = new Date()
    .toISOString()
    .replace(/[-:T.Z]/g, "")
    .slice(0, 14);
  const base = `mem_${stamp}_${type}_${slugify(title)}`;
  for (;;) {
    const id = `${base}_${randomUUID().slice(0, 8)}`;
    if (!existsSync(memoryFilePath(store.baseDir, store.projectPath, id))) return id;
  }
}

function writeRecord(store: MemoryStore, record: MemoryRecord): void {
  mkdirSync(projectMemoryDir(store.baseDir, store.projectPath), { recursive: true });
  writeFileSync(
    memoryFilePath(store.baseDir, store.projectPath, record.id),
    serializeMemory(record),
  );
}

/** Every memory for the project, most-recently-updated first. */
export function listMemories(store: MemoryStore): MemoryRecord[] {
  if (!hasProject(store)) return [];
  const dir = projectMemoryDir(store.baseDir, store.projectPath);
  let names: string[];
  try {
    names = readdirSync(dir);
  } catch {
    return [];
  }
  const records: MemoryRecord[] = [];
  for (const name of names) {
    if (!name.endsWith(".md")) continue;
    try {
      const record = parseMemory(readFileSync(path.join(dir, name), "utf8"));
      if (record) records.push(record);
    } catch {
      // Unreadable file — skip.
    }
  }
  return records.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
}

export function getMemory(store: MemoryStore, id: string): MemoryRecord | null {
  // Reject traversal ids before they reach a path join — this is what keeps a
  // caller-supplied id (write-by-id, mark-stale) inside its own project's dir.
  if (!hasProject(store) || !isSafeMemoryId(id)) return null;
  try {
    return parseMemory(readFileSync(memoryFilePath(store.baseDir, store.projectPath, id), "utf8"));
  } catch {
    return null;
  }
}

/** Memories eligible for recall/injection: active or pinned. */
function injectable(records: MemoryRecord[]): MemoryRecord[] {
  return records.filter((r) => r.status === "active" || r.status === "pinned");
}

/**
 * Write a memory. An `id` updates in place (reactivating a stale memory, since
 * the agent is asserting the fact is current); otherwise a new memory is
 * created, subject to secret scanning and the near-duplicate guard.
 */
export function writeMemory(store: MemoryStore, input: MemoryWriteInput): MemoryWriteResult {
  if (!hasProject(store)) {
    return {
      ok: false,
      reason: "no_project",
      message: "Memory needs a project — no project path is set for this session.",
    };
  }
  const secret = scanForSecrets(input.title, input.summary, input.body);
  if (secret.hasSecret) {
    return {
      ok: false,
      reason: "secret",
      message: `Write blocked: the content looks like it contains a secret (${secret.matched.join(", ")}). Remove it and try again.`,
    };
  }

  const now = new Date().toISOString();

  if (input.id) {
    const existing = getMemory(store, input.id);
    if (!existing) {
      return { ok: false, reason: "not_found", message: `No memory with id ${input.id}.` };
    }
    const updated: MemoryRecord = {
      ...existing,
      type: input.type,
      title: input.title,
      summary: input.summary,
      body: input.body,
      tags: input.tags ?? existing.tags,
      // Updating a stale memory reactivates it; otherwise keep pinned/active.
      status: input.status ?? (existing.status === "stale" ? "active" : existing.status),
      writeReason: input.writeReason ?? existing.writeReason,
      sourceAgentName: input.sourceAgentName ?? existing.sourceAgentName,
      updatedAt: now,
    };
    writeRecord(store, updated);
    return { ok: true, record: updated, created: false };
  }

  if (!input.confirmNew) {
    const candidateTerms = memoryTerms({
      title: input.title,
      summary: input.summary,
      tags: input.tags ?? [],
    });
    for (const existing of injectable(listMemories(store))) {
      if (overlapCoefficient(candidateTerms, memoryTerms(existing)) >= DUPLICATE_OVERLAP) {
        return {
          ok: false,
          reason: "duplicate",
          existing,
          message: `This looks like a near-duplicate of "${existing.title}" (id ${existing.id}). Pass that id to update it in place, or set confirmNew to store it as a distinct memory.`,
        };
      }
    }
  }

  const record: MemoryRecord = {
    id: uniqueId(store, input.type, input.title),
    type: input.type,
    scope: "project",
    status: input.status ?? "active",
    title: input.title,
    summary: input.summary,
    body: input.body,
    createdAt: now,
    updatedAt: now,
    tags: input.tags ?? [],
    writeReason: input.writeReason,
    sourceAgentName: input.sourceAgentName,
  };
  writeRecord(store, record);
  return { ok: true, record, created: true };
}

/** Change a memory's status (pin / stale / archive / re-activate). */
export function setMemoryStatus(
  store: MemoryStore,
  id: string,
  status: MemoryStatus,
): MemoryWriteResult {
  const existing = getMemory(store, id);
  if (!existing) {
    return { ok: false, reason: "not_found", message: `No memory with id ${id}.` };
  }
  const updated: MemoryRecord = { ...existing, status, updatedAt: new Date().toISOString() };
  writeRecord(store, updated);
  return { ok: true, record: updated, created: false };
}

/** Mark a memory stale so it stops being injected (kept for inspection). */
export function markStale(store: MemoryStore, id: string): MemoryWriteResult {
  return setMemoryStatus(store, id, "stale");
}

/** Permanently delete a memory file. Returns false if it didn't exist. */
export function deleteMemory(store: MemoryStore, id: string): boolean {
  // getMemory enforces the project guard + rejects traversal ids, so an unsafe
  // id can never reach unlink with a path outside the project dir.
  if (!getMemory(store, id)) return false;
  try {
    rmSync(memoryFilePath(store.baseDir, store.projectPath, id), { force: true });
    return true;
  } catch {
    return false;
  }
}

/**
 * Lexical recall over active/pinned memories: rank by the informative terms the
 * query shares with each memory's title/summary/tags, plus a smaller credit for
 * one-edit typo/near-miss matches (so "postgress migation" still recalls a
 * "Postgres migration" memory that exact overlap would miss). Small pinned
 * boost, recency as the tie-breaker. A fuzzy-only hit needs ≥ MIN_FUZZY_ONLY
 * near-misses so one coincidental near-miss can't surface an unrelated memory.
 * Abstains (empty) when the query carries no informative terms or nothing
 * matches. `sharedTerms` on a hit stays the EXACT overlap — fuzzy matches lift
 * the score but aren't reported as shared.
 */
export function searchMemories(
  store: MemoryStore,
  query: string,
  limit: number = DEFAULT_SEARCH_LIMIT,
): MemorySearchHit[] {
  const queryTerms = informativeTerms(query);
  if (queryTerms.size === 0) return [];
  const hits: MemorySearchHit[] = [];
  for (const record of injectable(listMemories(store))) {
    const memTerms = memoryTerms(record);
    const shared = sharedTerms(queryTerms, memTerms);
    const fuzzy = fuzzyMatchedTerms(queryTerms, memTerms);
    // An exact match alone qualifies; a fuzzy-only hit needs corroboration.
    if (shared.length < MIN_SHARED_TERMS && fuzzy.length < MIN_FUZZY_ONLY) continue;
    hits.push({
      record,
      score: shared.length + FUZZY_WEIGHT * fuzzy.length + (record.status === "pinned" ? 0.5 : 0),
      sharedTerms: shared,
    });
  }
  hits.sort((a, b) => b.score - a.score || b.record.updatedAt.localeCompare(a.record.updatedAt));
  return hits.slice(0, limit);
}

/** Text embedded for a memory's semantic vector — title + summary + body. */
function memoryEmbedText(record: MemoryRecord): string {
  return [record.title, record.summary, record.body].filter(Boolean).join("\n");
}

/**
 * Semantic recall (native AgentMemoryEmbedder): rank memories by mean-centered
 * cosine of an embedding, BLENDED with the lexical signal so exact-term hits
 * still win when they exist while a semantically-related query with no shared
 * words is still recalled. The Embedder is injected (a real on-device model in
 * production; a stub in tests). Falls back to pure lexical if embedding fails.
 */
export async function semanticSearchMemories(
  store: MemoryStore,
  query: string,
  embedder: Embedder,
  options: { limit?: number; semanticWeight?: number } = {},
): Promise<MemorySearchHit[]> {
  const limit = Math.max(0, options.limit ?? DEFAULT_SEARCH_LIMIT);
  const semanticWeight = Math.min(1, Math.max(0, options.semanticWeight ?? 0.7));
  const records = injectable(listMemories(store));
  if (records.length === 0 || !query.trim()) return [];

  let semanticScores: number[];
  try {
    const vectors = await embedder.embed([query, ...records.map(memoryEmbedText)]);
    const [queryVec, ...docVecs] = vectors;
    if (!queryVec || docVecs.length !== records.length) throw new Error("embedding shape mismatch");
    // Centered cosine is ~[-1,1]; normalize to [0,1] to blend with the lexical score.
    semanticScores = centeredCosineScores(queryVec, docVecs).map((s) => (s + 1) / 2);
  } catch {
    // Embedding unavailable/failed — fall back to the lexical ranking.
    return searchMemories(store, query, limit);
  }

  // Normalize the lexical scores into [0,1] so the blend weight is meaningful.
  const lexicalById = new Map(
    searchMemories(store, query, records.length).map((hit) => [hit.record.id, hit.score]),
  );
  const maxLexical = Math.max(1, ...lexicalById.values());

  const hits: MemorySearchHit[] = records.map((record, index) => {
    const semantic = semanticScores[index] ?? 0;
    const lexical = (lexicalById.get(record.id) ?? 0) / maxLexical;
    const pin = record.status === "pinned" ? 0.05 : 0;
    return {
      record,
      score: semanticWeight * semantic + (1 - semanticWeight) * lexical + pin,
      sharedTerms: sharedTerms(informativeTerms(query), memoryTerms(record)),
    };
  });
  hits.sort((a, b) => b.score - a.score || b.record.updatedAt.localeCompare(a.record.updatedAt));
  return hits.slice(0, limit);
}

/**
 * The project memory index injected at launch (memory.md §Memory Policy
 * Injection): one line per injectable memory — id · type · title — summary — so
 * the agent knows what is stored before deciding to write or search. Bodies are
 * never here.
 */
export function injectableIndex(
  store: MemoryStore,
  cap: number = DEFAULT_INDEX_CAP,
): { lines: string[]; overflow: number } {
  const records = injectable(listMemories(store));
  const lines = records.slice(0, cap).map((r) => `${r.id} · ${r.type} · ${r.title} — ${r.summary}`);
  return { lines, overflow: Math.max(0, records.length - cap) };
}
