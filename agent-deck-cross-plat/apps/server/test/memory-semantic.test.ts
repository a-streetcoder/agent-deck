import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import type { Embedder } from "@agent-deck/memory";
import { afterEach, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * The semantic-recall OPT-IN wired through the server. An embedder injected via
 * StartServerOptions routes /memory/search (and the bridge tool + recall hook)
 * through semantic ranking; without one, recall stays lexical+fuzzy. Hermetic: a
 * concept-keyword stub embedder stands in for the real on-device model (no
 * download), proving a lexically-DISJOINT query recalls the right memory only
 * when the embedder is present.
 */

process.env.AGENT_DECK_TEST = "1";

const CONCEPTS: Array<{ dim: number; triggers: string[] }> = [
  { dim: 0, triggers: ["login", "oauth", "credentials", "token", "authenticate", "signin"] },
  { dim: 1, triggers: ["schema", "sql", "migration", "database", "postgres", "reindex"] },
];

const conceptEmbedder: Embedder = {
  async embed(texts) {
    return texts.map((text) => {
      const words = text
        .toLowerCase()
        .split(/[^a-z0-9]+/)
        .filter(Boolean);
      const vec = new Array<number>(CONCEPTS.length).fill(0.01);
      for (const { dim, triggers } of CONCEPTS) {
        for (const word of words) if (triggers.includes(word)) vec[dim]! += 1;
      }
      const norm = Math.sqrt(vec.reduce((s, x) => s + x * x, 0));
      return vec.map((x) => x / norm);
    });
  },
};

let server: AgentDeckServer | undefined;

afterEach(async () => {
  await server?.close();
  server = undefined;
});

async function setup(embedder?: Embedder): Promise<{ projectId: string }> {
  const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));
  const project = mkdtempSync(path.join(tmpdir(), "proj-"));
  server = await startServer({ dataDir, memoryEmbedder: embedder });
  const base = `http://127.0.0.1:${server.port}`;

  const created = (await (
    await fetch(`${base}/projects`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path: project }),
    })
  ).json()) as { project: { id: string } };
  const projectId = created.project.id;

  const memories = [
    {
      type: "context",
      title: "Login credentials",
      summary: "Where the oauth token lives",
      body: "Keep the oauth credentials and login token in auth.json.",
    },
    {
      type: "context",
      title: "Schema migrations",
      summary: "Applying schema changes",
      body: "Apply the sql schema migration to the database.",
    },
  ];
  for (const m of memories) {
    const res = await fetch(`${base}/memory`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ projectId, ...m }),
    });
    expect(res.status).toBe(201);
  }
  return { projectId };
}

async function search(projectId: string, q: string): Promise<string[]> {
  const base = `http://127.0.0.1:${server!.port}`;
  const res = await fetch(
    `${base}/memory/search?projectId=${encodeURIComponent(projectId)}&q=${encodeURIComponent(q)}`,
  );
  const { memories } = (await res.json()) as { memories: Array<{ title: string }> };
  return memories.map((m) => m.title);
}

describe("semantic memory opt-in via /memory/search", () => {
  it("recalls a concept-matched memory for a lexically-disjoint query WHEN an embedder is injected", async () => {
    const { projectId } = await setup(conceptEmbedder);
    // "authenticate a signin" shares no informative term with the credentials
    // memory, so lexical recall abstains — but the auth concept matches.
    const titles = await search(projectId, "how do I authenticate a signin");
    expect(titles[0]).toBe("Login credentials");
  });

  it("abstains on the same disjoint query with NO embedder (lexical default)", async () => {
    const { projectId } = await setup(undefined);
    const titles = await search(projectId, "how do I authenticate a signin");
    expect(titles).toHaveLength(0);
  });

  it("still finds an exact-term match under the lexical default", async () => {
    const { projectId } = await setup(undefined);
    const titles = await search(projectId, "oauth token");
    expect(titles).toContain("Login credentials");
  });
});
