import {
  markStale,
  searchMemories,
  writeMemory,
  type MemorySearchHit,
  type MemoryStore,
  type MemoryType,
} from "@agent-deck/memory";
import { z } from "zod";
import type { BridgeRegistry } from "./bridge.ts";

/** Ranks a project's memories for a query. Async so a semantic (embedding-backed)
 *  ranker can be injected; defaults to the lexical+fuzzy searchMemories. */
export type MemorySearch = (
  store: MemoryStore,
  query: string,
  limit?: number,
) => Promise<MemorySearchHit[]>;

/**
 * Registers the native memory tools (agent_deck_memory_write / _search /
 * _mark_stale) on the bridge, backed by the project-scoped Markdown store. Each
 * call is scoped to the calling session's project via resolveProjectPath — so a
 * session only ever reads/writes its own project's memory. When a session has
 * no project path, writes are refused and search is empty (memory.md: no
 * project ⇒ no memory).
 */

const MEMORY_TYPES = ["context", "decision", "runbook", "failure", "preference"] as const;

/** Per-hit body cap so one large memory can't blow up the tool result. */
const MAX_BODY_CHARS = 1200;

function clampBody(body: string): string {
  return body.length > MAX_BODY_CHARS ? `${body.slice(0, MAX_BODY_CHARS)}\n…[truncated]` : body;
}

const writeParams = z.object({
  type: z.enum(MEMORY_TYPES),
  title: z.string().min(1),
  summary: z.string().min(1),
  body: z.string().min(1),
  tags: z.array(z.string()).optional(),
  id: z.string().optional(),
  confirmNew: z.boolean().optional(),
  writeReason: z.string().optional(),
});

const searchParams = z.object({
  query: z.string().min(1),
  limit: z.number().int().positive().max(20).optional(),
});

const markStaleParams = z.object({ id: z.string().min(1) });

export function registerMemoryTools(
  bridge: BridgeRegistry,
  baseDir: string,
  resolveProjectPath: (sessionId: string) => string | undefined,
  search: MemorySearch = (store, query, limit) =>
    Promise.resolve(searchMemories(store, query, limit)),
): void {
  const storeFor = (sessionId: string): MemoryStore | null => {
    const projectPath = resolveProjectPath(sessionId);
    return projectPath ? { baseDir, projectPath } : null;
  };

  bridge.register(
    {
      name: "agent_deck_memory_write",
      label: "Write memory",
      description:
        "Store durable project memory a future session can't rediscover from the repo — a decision and its rationale, a failed approach, a user correction, a runbook, or a non-obvious gotcha. Pass an existing id to update in place; omit it to create. Never store secrets or transient task state.",
      parameters: {
        type: "object",
        properties: {
          type: { type: "string", enum: [...MEMORY_TYPES] },
          title: { type: "string", description: "Short title." },
          summary: {
            type: "string",
            description: "A retrieval key: the words a future question about this would use.",
          },
          body: { type: "string", description: "The durable content." },
          tags: { type: "array", items: { type: "string" } },
          id: { type: "string", description: "Update this memory in place instead of creating." },
          confirmNew: {
            type: "boolean",
            description: "Store as distinct even if it looks like a near-duplicate.",
          },
          writeReason: { type: "string" },
        },
        required: ["type", "title", "summary", "body"],
        additionalProperties: false,
      },
      promptSnippet:
        "agent_deck_memory_write — persist a durable project fact (decision/failure/runbook/context/preference).",
    },
    (params, ctx) => {
      const store = storeFor(ctx.sessionId);
      if (!store) {
        return { content: "Memory needs a project; none is set for this session.", isError: true };
      }
      const parsed = writeParams.safeParse(params);
      if (!parsed.success) {
        return {
          content: `Invalid memory_write arguments: ${parsed.error.message}`,
          isError: true,
        };
      }
      const result = writeMemory(store, { ...parsed.data, type: parsed.data.type as MemoryType });
      if (result.ok) {
        return {
          content: `${result.created ? "Stored" : "Updated"} memory ${result.record.id}: ${result.record.title}`,
          details: { id: result.record.id, created: result.created },
        };
      }
      if (result.reason === "duplicate") {
        // Actionable guidance, not a failure: the model should update or confirm.
        return { content: result.message, details: { existingId: result.existing.id } };
      }
      return { content: result.message, isError: true };
    },
  );

  bridge.register(
    {
      name: "agent_deck_memory_search",
      label: "Search memory",
      description:
        "Recall relevant project memory on demand when the conversation moves to a topic beyond what launch-time recall covered. Returns matching memories ranked by relevance.",
      parameters: {
        type: "object",
        properties: {
          query: { type: "string", description: "What you're trying to recall." },
          limit: {
            type: "integer",
            minimum: 1,
            maximum: 20,
            description: "Max results (default 8).",
          },
        },
        required: ["query"],
        additionalProperties: false,
      },
      promptSnippet: "agent_deck_memory_search — pull relevant project memory mid-conversation.",
    },
    async (params, ctx) => {
      const store = storeFor(ctx.sessionId);
      if (!store) return { content: "No project memory (no project set).", details: { hits: 0 } };
      const parsed = searchParams.safeParse(params);
      if (!parsed.success) {
        return {
          content: `Invalid memory_search arguments: ${parsed.error.message}`,
          isError: true,
        };
      }
      const hits = await search(store, parsed.data.query, parsed.data.limit);
      if (hits.length === 0)
        return { content: "No matching project memory.", details: { hits: 0 } };
      const rendered = hits
        .map(
          (h) =>
            `### ${h.record.title} (${h.record.type}, id ${h.record.id})\n${clampBody(h.record.body)}`,
        )
        .join("\n\n");
      return { content: rendered, details: { hits: hits.length } };
    },
  );

  bridge.register(
    {
      name: "agent_deck_memory_mark_stale",
      label: "Mark memory stale",
      description:
        "Mark a project memory stale when the current repository or a user correction proves it wrong. It stops being injected but stays inspectable.",
      parameters: {
        type: "object",
        properties: { id: { type: "string", description: "The memory id to mark stale." } },
        required: ["id"],
        additionalProperties: false,
      },
      promptSnippet:
        "agent_deck_memory_mark_stale — retire a memory the repo has since contradicted.",
    },
    (params, ctx) => {
      const store = storeFor(ctx.sessionId);
      if (!store) return { content: "No project memory (no project set).", isError: true };
      const parsed = markStaleParams.safeParse(params);
      if (!parsed.success) {
        return { content: `Invalid mark_stale arguments: ${parsed.error.message}`, isError: true };
      }
      const result = markStale(store, parsed.data.id);
      return result.ok
        ? { content: `Marked memory ${result.record.id} stale.` }
        : { content: result.message, isError: true };
    },
  );
}
