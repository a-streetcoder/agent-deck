import {
  deleteMemory,
  getMemory,
  listMemories,
  setMemoryStatus,
  writeMemory,
  type MemoryStore,
  type MemoryType,
} from "@agent-deck/memory";
import { z } from "zod";
import type { ServerContext } from "../context.ts";

/**
 * Memory inspection routes — browse/search/manage a project's stored memories
 * (the visible half of memory.md). Moved verbatim from server.ts.
 */
export function registerMemoryRoutes(ctx: ServerContext): void {
  const { fastify, projects, memoryEnabled, memoryBaseDir, recallMemories, broadcast } = ctx;

  // Memory inspection: browse and manage a project's stored memories (the
  // visible half of memory.md). Project-scoped by the project's path — the same
  // key its sessions write under — so one project never sees another's.
  const memoryStoreFor = (projectId?: string): MemoryStore | null => {
    if (!memoryEnabled || !projectId) return null;
    const project = projects.find((p) => p.id === projectId);
    return project ? { baseDir: memoryBaseDir, projectPath: project.path } : null;
  };

  const memoryPatchBody = z
    .object({
      projectId: z.string(),
      status: z.enum(["active", "pinned", "stale", "archived"]).optional(),
      edit: z
        .object({
          type: z.enum(["context", "decision", "runbook", "failure", "preference"]),
          title: z.string().min(1),
          summary: z.string().min(1),
          body: z.string().min(1),
          tags: z.array(z.string()).optional(),
        })
        .optional(),
    })
    // A PATCH must change something — status or edit — else it's a bad request.
    .refine((v) => v.status !== undefined || v.edit !== undefined, {
      message: "provide status or edit",
    });

  const memoryCreateBody = z.object({
    projectId: z.string(),
    type: z.enum(["context", "decision", "runbook", "failure", "preference"]),
    title: z.string().min(1),
    summary: z.string().min(1),
    body: z.string().min(1),
    tags: z.array(z.string()).optional(),
  });

  fastify.get("/memory", async (request, reply) => {
    const store = memoryStoreFor((request.query as { projectId?: string }).projectId);
    if (!store) return reply.code(400).send({ error: "memory requires a known project" });
    return { memories: listMemories(store) };
  });

  // Memory recall search (native Memory search 11.8): runs the SAME recall engine
  // the agent recalls with (recallMemories — lexical+fuzzy, or semantic when
  // opted in) and returns the ranked hits — active/pinned only, abstaining
  // (empty) when nothing matches.
  fastify.get("/memory/search", async (request, reply) => {
    const { projectId, q } = request.query as { projectId?: string; q?: string };
    const store = memoryStoreFor(projectId);
    if (!store) return reply.code(400).send({ error: "memory requires a known project" });
    const query = (q ?? "").trim();
    if (!query) return { memories: [] };
    return { memories: (await recallMemories(store, query)).map((hit) => hit.record) };
  });

  fastify.post("/memory", async (request, reply) => {
    const parsed = memoryCreateBody.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.message });
    const store = memoryStoreFor(parsed.data.projectId);
    if (!store) return reply.code(400).send({ error: "memory requires a known project" });
    // A manual UI create is deliberate — bypass the near-duplicate guard.
    const result = writeMemory(store, {
      ...parsed.data,
      type: parsed.data.type as MemoryType,
      confirmNew: true,
    });
    if (!result.ok) return reply.code(400).send({ error: result.message });
    broadcast({ type: "resources_changed" });
    return reply.code(201).send({ memory: result.record });
  });

  fastify.get("/memory/:id", async (request, reply) => {
    const store = memoryStoreFor((request.query as { projectId?: string }).projectId);
    if (!store) return reply.code(400).send({ error: "memory requires a known project" });
    const memory = getMemory(store, (request.params as { id: string }).id);
    if (!memory) return reply.code(404).send({ error: "unknown memory" });
    return { memory };
  });

  fastify.patch("/memory/:id", async (request, reply) => {
    const parsed = memoryPatchBody.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.message });
    const store = memoryStoreFor(parsed.data.projectId);
    if (!store) return reply.code(400).send({ error: "memory requires a known project" });
    const { id } = request.params as { id: string };
    // The schema guarantees status or edit is present.
    const result = parsed.data.edit
      ? writeMemory(store, { id, ...parsed.data.edit, type: parsed.data.edit.type as MemoryType })
      : setMemoryStatus(store, id, parsed.data.status!);
    if (!result.ok) {
      return reply.code(result.reason === "not_found" ? 404 : 400).send({ error: result.message });
    }
    broadcast({ type: "resources_changed" });
    return { memory: result.record };
  });

  fastify.delete("/memory/:id", async (request, reply) => {
    const store = memoryStoreFor((request.query as { projectId?: string }).projectId);
    if (!store) return reply.code(400).send({ error: "memory requires a known project" });
    if (!deleteMemory(store, (request.params as { id: string }).id)) {
      return reply.code(404).send({ error: "unknown memory" });
    }
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });
}
