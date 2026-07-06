import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { writeMemory, type MemoryRecord, type MemoryStore } from "@agent-deck/memory";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * Memory inspection REST (the visible half): list / get / patch (status +
 * edit) / delete a project's memories, project-scoped. No pi is spawned — this
 * exercises the routes against the Markdown store directly.
 */

let server: AgentDeckServer;
let projectId: string;
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));
const projectDir = mkdtempSync(path.join(tmpdir(), "mem-routes-project-"));

async function api(method: string, url: string, body?: unknown): Promise<Response> {
  return await fetch(`http://127.0.0.1:${server.port}${url}`, {
    method,
    // Only send a JSON content-type when there's a body — Fastify rejects an
    // empty body when content-type is application/json (e.g. GET/DELETE).
    headers: body === undefined ? {} : { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

beforeAll(async () => {
  server = await startServer({ dataDir });
  const created = (await (await api("POST", "/projects", { path: projectDir })).json()) as {
    project: { id: string; path: string };
  };
  projectId = created.project.id;
  // Seed two memories into the same project store the routes read.
  const store: MemoryStore = {
    baseDir: path.join(dataDir, "memory"),
    projectPath: created.project.path,
  };
  writeMemory(store, {
    type: "decision",
    title: "Use pnpm",
    summary: "pnpm workspaces",
    body: "b1",
  });
  writeMemory(store, { type: "runbook", title: "Run tests", summary: "pnpm test", body: "b2" });
});

afterAll(async () => {
  await server.close();
});

describe("memory inspection routes", () => {
  it("requires a known project", async () => {
    expect((await api("GET", "/memory")).status).toBe(400);
    expect((await api("GET", "/memory?projectId=nope")).status).toBe(400);
  });

  it("lists a project's memories", async () => {
    const { memories } = (await (await api("GET", `/memory?projectId=${projectId}`)).json()) as {
      memories: MemoryRecord[];
    };
    expect(memories).toHaveLength(2);
    expect(memories.map((m) => m.title).sort()).toEqual(["Run tests", "Use pnpm"]);
  });

  it("pins and re-activates via PATCH status", async () => {
    const list = (await (await api("GET", `/memory?projectId=${projectId}`)).json()) as {
      memories: MemoryRecord[];
    };
    const id = list.memories.find((m) => m.title === "Use pnpm")!.id;

    const pinned = (await (
      await api("PATCH", `/memory/${id}`, { projectId, status: "pinned" })
    ).json()) as {
      memory: MemoryRecord;
    };
    expect(pinned.memory.status).toBe("pinned");

    const got = (await (await api("GET", `/memory/${id}?projectId=${projectId}`)).json()) as {
      memory: MemoryRecord;
    };
    expect(got.memory.status).toBe("pinned");
  });

  it("edits a memory via PATCH edit", async () => {
    const list = (await (await api("GET", `/memory?projectId=${projectId}`)).json()) as {
      memories: MemoryRecord[];
    };
    const id = list.memories.find((m) => m.title === "Run tests")!.id;

    const edited = (await (
      await api("PATCH", `/memory/${id}`, {
        projectId,
        edit: {
          type: "runbook",
          title: "Run tests",
          summary: "pnpm test with a clean cache",
          body: "b2b",
        },
      })
    ).json()) as { memory: MemoryRecord };
    expect(edited.memory.summary).toContain("clean cache");
    expect(edited.memory.id).toBe(id); // updated in place
  });

  it("rejects a PATCH that changes nothing with 400", async () => {
    const list = (await (await api("GET", `/memory?projectId=${projectId}`)).json()) as {
      memories: MemoryRecord[];
    };
    const id = list.memories[0]!.id;
    expect((await api("PATCH", `/memory/${id}`, { projectId })).status).toBe(400);
  });

  it("deletes a memory", async () => {
    const list = (await (await api("GET", `/memory?projectId=${projectId}`)).json()) as {
      memories: MemoryRecord[];
    };
    const id = list.memories[0]!.id;
    expect((await api("DELETE", `/memory/${id}?projectId=${projectId}`)).status).toBe(200);
    expect((await api("GET", `/memory/${id}?projectId=${projectId}`)).status).toBe(404);
    // A second delete 404s.
    expect((await api("DELETE", `/memory/${id}?projectId=${projectId}`)).status).toBe(404);
  });
});
