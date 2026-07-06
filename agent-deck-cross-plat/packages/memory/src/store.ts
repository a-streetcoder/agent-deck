import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { parseMemory, serializeMemory } from "./frontmatter.ts";
import { isSafeMemoryId, memoryFilePath, projectMemoryDir } from "./paths.ts";
import { scanForSecrets } from "./secrets.ts";
import { informativeTerms, memoryTerms, overlapCoefficient, sharedTerms } from "./text.ts";
import type {
  MemoryRecord,
  MemorySearchHit,
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
/** A memory must share at least this many informative terms to be a search hit. */
const MIN_SHARED_TERMS = 1;
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

/** Mark a memory stale so it stops being injected (kept for inspection). */
export function markStale(store: MemoryStore, id: string): MemoryWriteResult {
  const existing = getMemory(store, id);
  if (!existing) {
    return { ok: false, reason: "not_found", message: `No memory with id ${id}.` };
  }
  const updated: MemoryRecord = {
    ...existing,
    status: "stale",
    updatedAt: new Date().toISOString(),
  };
  writeRecord(store, updated);
  return { ok: true, record: updated, created: false };
}

/**
 * Lexical recall over active/pinned memories: rank by the number of informative
 * terms the query shares with each memory's title/summary/tags, with a small
 * pinned boost and recency as the tie-breaker. Abstains (empty) when the query
 * carries no informative terms or nothing shares one.
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
    const shared = sharedTerms(queryTerms, memoryTerms(record));
    if (shared.length < MIN_SHARED_TERMS) continue;
    hits.push({
      record,
      score: shared.length + (record.status === "pinned" ? 0.5 : 0),
      sharedTerms: shared,
    });
  }
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
