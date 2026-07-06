import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { beforeEach, describe, expect, it } from "vitest";
import {
  deleteMemory,
  getMemory,
  injectableIndex,
  listMemories,
  markStale,
  searchMemories,
  setMemoryStatus,
  writeMemory,
  type MemoryStore,
} from "../src/index.ts";

let store: MemoryStore;

beforeEach(() => {
  store = {
    baseDir: mkdtempSync(path.join(tmpdir(), "agent-deck-mem-")),
    projectPath: mkdtempSync(path.join(tmpdir(), "proj-")),
  };
});

describe("memory store", () => {
  it("creates a memory and round-trips it through the Markdown file", () => {
    const result = writeMemory(store, {
      type: "runbook",
      title: "Run the tests",
      summary: "Use pnpm test with an isolated cache",
      body: "Run `pnpm test`. If the cache is stale, clear node_modules/.vite.",
      tags: ["tests", "ci"],
    });
    expect(result.ok).toBe(true);
    if (!result.ok) throw new Error("unreachable");
    expect(result.created).toBe(true);
    expect(result.record.id).toMatch(/^mem_\d{14}_runbook_run-the-tests_/);

    const reloaded = getMemory(store, result.record.id);
    expect(reloaded).toMatchObject({
      type: "runbook",
      title: "Run the tests",
      summary: "Use pnpm test with an isolated cache",
      tags: ["tests", "ci"],
      status: "active",
      scope: "project",
    });
    expect(reloaded!.body).toContain("pnpm test");
  });

  it("updates in place when given an existing id (and reactivates if stale)", () => {
    const created = writeMemory(store, {
      type: "decision",
      title: "Use Fastify",
      summary: "The server uses Fastify for REST + ws",
      body: "Chosen for the ws integration.",
    });
    if (!created.ok) throw new Error("unreachable");
    markStale(store, created.record.id);
    expect(getMemory(store, created.record.id)!.status).toBe("stale");

    const updated = writeMemory(store, {
      id: created.record.id,
      type: "decision",
      title: "Use Fastify",
      summary: "The server uses Fastify for REST + ws + the bridge route",
      body: "Chosen for ws; also hosts /bridge.",
    });
    expect(updated.ok).toBe(true);
    if (!updated.ok) throw new Error("unreachable");
    expect(updated.created).toBe(false);
    // Same id, reactivated, one file only.
    expect(updated.record.id).toBe(created.record.id);
    expect(updated.record.status).toBe("active");
    expect(listMemories(store)).toHaveLength(1);
    expect(getMemory(store, created.record.id)!.summary).toContain("bridge route");
  });

  it("holds a near-duplicate create and points at the existing memory", () => {
    const first = writeMemory(store, {
      type: "context",
      title: "Streaming passthrough contract",
      summary: "text_delta events must reach the UI incrementally",
      body: "The enshrined streaming assertion.",
    });
    if (!first.ok) throw new Error("unreachable");

    const dup = writeMemory(store, {
      type: "context",
      title: "Streaming passthrough",
      summary: "text_delta events reach the UI incrementally as they stream",
      body: "Slightly reworded restatement.",
    });
    expect(dup.ok).toBe(false);
    if (dup.ok) throw new Error("unreachable");
    expect(dup.reason).toBe("duplicate");
    if (dup.reason !== "duplicate") throw new Error("unreachable");
    expect(dup.existing.id).toBe(first.record.id);
    // Only the original persisted.
    expect(listMemories(store)).toHaveLength(1);
  });

  it("stores a genuinely distinct fact even in the same domain", () => {
    writeMemory(store, {
      type: "context",
      title: "Streaming passthrough contract",
      summary: "text_delta events must reach the UI incrementally",
      body: "x",
    });
    const distinct = writeMemory(store, {
      type: "runbook",
      title: "Release checklist",
      summary: "Tag the version and push to the release branch",
      body: "y",
    });
    expect(distinct.ok).toBe(true);
    expect(listMemories(store)).toHaveLength(2);
  });

  it("overrides the duplicate guard with confirmNew", () => {
    writeMemory(store, { type: "context", title: "A B C", summary: "a b c", body: "x" });
    const forced = writeMemory(store, {
      type: "context",
      title: "A B C",
      summary: "a b c",
      body: "x",
      confirmNew: true,
    });
    expect(forced.ok).toBe(true);
    expect(listMemories(store)).toHaveLength(2);
  });

  it("blocks writes that contain a secret", () => {
    const result = writeMemory(store, {
      type: "context",
      title: "Prod credentials",
      summary: "the key",
      body: "api_key = sk-abcdef0123456789ABCDEF",
    });
    expect(result.ok).toBe(false);
    if (result.ok) throw new Error("unreachable");
    expect(result.reason).toBe("secret");
    expect(listMemories(store)).toHaveLength(0);
  });

  it("searches by lexical overlap and excludes stale/archived memories", () => {
    const keep = writeMemory(store, {
      type: "runbook",
      title: "Deploy the server",
      summary: "Push to the deploy branch and watch the pipeline",
      body: "x",
      tags: ["deploy"],
    });
    if (!keep.ok) throw new Error("unreachable");
    const stale = writeMemory(store, {
      type: "runbook",
      title: "Old deploy steps",
      summary: "Deploy manually over ssh",
      body: "y",
    });
    if (!stale.ok) throw new Error("unreachable");
    markStale(store, stale.record.id);

    const hits = searchMemories(store, "how do I deploy the server pipeline");
    expect(hits.length).toBe(1);
    expect(hits[0]!.record.id).toBe(keep.record.id);
    expect(hits[0]!.sharedTerms).toContain("deploy");

    // A query with no informative overlap returns nothing (no "hello" recall).
    expect(searchMemories(store, "hello there")).toHaveLength(0);
  });

  it("builds a bodyless project memory index of injectable memories", () => {
    const a = writeMemory(store, {
      type: "decision",
      title: "Use pnpm",
      summary: "Monorepo uses pnpm workspaces",
      body: "secret-free body",
    });
    if (!a.ok) throw new Error("unreachable");
    const b = writeMemory(store, {
      type: "failure",
      title: "Do not mock the backend",
      summary: "Attempt 1 failed because e2e mocked pi",
      body: "another body",
    });
    if (!b.ok) throw new Error("unreachable");
    markStale(store, b.record.id);

    const index = injectableIndex(store);
    expect(index.overflow).toBe(0);
    // Only the active one is indexed; the line carries no body.
    expect(index.lines).toHaveLength(1);
    expect(index.lines[0]).toContain("Use pnpm");
    expect(index.lines[0]).toContain("Monorepo uses pnpm workspaces");
    expect(index.lines[0]).not.toContain("secret-free body");
  });

  it("rejects writes and returns nothing when no project path is set", () => {
    const noProject: MemoryStore = { baseDir: store.baseDir, projectPath: "  " };
    const write = writeMemory(noProject, {
      type: "context",
      title: "x",
      summary: "y",
      body: "z",
    });
    expect(write.ok).toBe(false);
    if (write.ok) throw new Error("unreachable");
    expect(write.reason).toBe("no_project");
    expect(listMemories(noProject)).toHaveLength(0);
    expect(searchMemories(noProject, "anything")).toHaveLength(0);
  });

  it("isolates memory per project (no cross-project leakage)", () => {
    const other: MemoryStore = {
      baseDir: store.baseDir,
      projectPath: mkdtempSync(path.join(tmpdir(), "proj-other-")),
    };
    writeMemory(store, { type: "context", title: "Only here", summary: "s", body: "b" });
    expect(listMemories(store)).toHaveLength(1);
    expect(listMemories(other)).toHaveLength(0);
  });

  it("changes status (pin / archive / re-activate) and reflects it in injection", () => {
    const created = writeMemory(store, {
      type: "preference",
      title: "Tabs vs spaces",
      summary: "This project uses two-space indent",
      body: "x",
    });
    if (!created.ok) throw new Error("unreachable");
    const id = created.record.id;

    expect(setMemoryStatus(store, id, "pinned").ok).toBe(true);
    expect(getMemory(store, id)!.status).toBe("pinned");
    // Pinned memories are still injected.
    expect(injectableIndex(store).lines).toHaveLength(1);

    // Archiving removes it from injection but keeps the file.
    expect(setMemoryStatus(store, id, "archived").ok).toBe(true);
    expect(injectableIndex(store).lines).toHaveLength(0);
    expect(listMemories(store)).toHaveLength(1);

    // Re-activating brings it back.
    expect(setMemoryStatus(store, id, "active").ok).toBe(true);
    expect(injectableIndex(store).lines).toHaveLength(1);

    expect(setMemoryStatus(store, "no-such-id", "pinned").ok).toBe(false);
  });

  it("deletes a memory file (and reports whether it existed)", () => {
    const created = writeMemory(store, {
      type: "context",
      title: "Delete me",
      summary: "s",
      body: "b",
    });
    if (!created.ok) throw new Error("unreachable");
    expect(deleteMemory(store, created.record.id)).toBe(true);
    expect(getMemory(store, created.record.id)).toBeNull();
    expect(listMemories(store)).toHaveLength(0);
    // Deleting a missing or traversal id is a no-op returning false.
    expect(deleteMemory(store, created.record.id)).toBe(false);
    expect(deleteMemory(store, "../escape")).toBe(false);
  });

  it("rejects path-traversal ids so a call can't reach another project's files", () => {
    writeMemory(store, { type: "context", title: "safe", summary: "s", body: "b" });
    // A crafted id with separators / ".." must not read or update anything.
    expect(getMemory(store, "../../etc/passwd")).toBeNull();
    expect(getMemory(store, "sub/dir/id")).toBeNull();
    const update = writeMemory(store, {
      id: "../escape",
      type: "context",
      title: "x",
      summary: "y",
      body: "z",
    });
    expect(update.ok).toBe(false);
    if (update.ok) throw new Error("unreachable");
    expect(update.reason).toBe("not_found");
    const stale = markStale(store, "../escape");
    expect(stale.ok).toBe(false);
  });
});
