import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { beforeEach, describe, expect, it } from "vitest";
import {
  centeredCosineScores,
  cosineSimilarity,
  meanCenter,
  searchMemories,
  semanticSearchMemories,
  writeMemory,
  type Embedder,
  type MemoryStore,
} from "../src/index.ts";

/**
 * A hermetic stub for the on-device embedder: it maps text to an L2-normalized
 * vector over a handful of CONCEPTS by counting trigger words. Normalizing keeps
 * it faithful to real sentence embeddings (which are ~unit norm), so a query
 * that weakly triggers a concept still lands near a doc that strongly triggers
 * the same concept. This exercises the blended search's key property — recalling
 * a memory whose CONCEPT matches the query even when the two share no literal
 * words — without downloading a real model.
 *
 * Each concept splits its triggers: DOC words appear in the memories, PROBE
 * words only in the queries, so the concept match is never a lexical one.
 */
const CONCEPTS: Array<{ dim: number; triggers: string[] }> = [
  {
    dim: 0,
    triggers: ["login", "oauth", "credentials", "token", "authenticate", "signin", "password"],
  },
  { dim: 1, triggers: ["schema", "sql", "migration", "database", "postgres", "query", "reindex"] },
  { dim: 2, triggers: ["release", "pipeline", "ci", "build", "ship", "deploy", "rollout"] },
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

let store: MemoryStore;

beforeEach(() => {
  store = {
    baseDir: mkdtempSync(path.join(tmpdir(), "agent-deck-mem-")),
    projectPath: mkdtempSync(path.join(tmpdir(), "proj-")),
  };
});

describe("semantic scoring math", () => {
  it("mean-centers vectors around their centroid", () => {
    const centered = meanCenter([
      [1, 0],
      [3, 0],
    ]);
    expect(centered).toEqual([
      [-1, 0],
      [1, 0],
    ]);
  });

  it("cosine of a vector with itself is 1, orthogonal is 0", () => {
    expect(cosineSimilarity([1, 2, 3], [1, 2, 3])).toBeCloseTo(1);
    expect(cosineSimilarity([1, 0], [0, 1])).toBeCloseTo(0);
    expect(cosineSimilarity([0, 0], [1, 1])).toBe(0);
  });

  it("centered cosine separates a related doc from an unrelated one", () => {
    const scores = centeredCosineScores(
      [1, 0],
      [
        [1, 0],
        [0, 1],
      ],
    );
    expect(scores[0]!).toBeGreaterThan(scores[1]!);
  });
});

describe("semanticSearchMemories", () => {
  beforeEach(() => {
    writeMemory(store, {
      type: "context",
      title: "Login credentials",
      summary: "Where the oauth token lives",
      body: "Keep the oauth credentials and login token in auth.json.",
      tags: [],
    });
    writeMemory(store, {
      type: "context",
      title: "Schema migrations",
      summary: "Applying schema changes",
      body: "Apply the sql schema migration to the database.",
      tags: [],
    });
    writeMemory(store, {
      type: "context",
      title: "Release pipeline",
      summary: "How code ships",
      body: "The ci pipeline runs the build and ships the release.",
      tags: [],
    });
  });

  it("recalls a concept-matched memory that shares NO words with the query", async () => {
    // "authenticate a signin" is lexically disjoint from the credentials memory
    // (no shared/fuzzy terms) yet maps to the same auth concept.
    const query = "how do I authenticate a signin";

    // Lexical search alone cannot find it — nothing shares a term.
    expect(searchMemories(store, query)).toHaveLength(0);

    const hits = await semanticSearchMemories(store, query, conceptEmbedder);
    expect(hits[0]?.record.title).toBe("Login credentials");
  });

  it("surfaces the concept-matched memory for a lexically-disjoint database query", async () => {
    const query = "postgres reindex";
    expect(searchMemories(store, query)).toHaveLength(0);

    const hits = await semanticSearchMemories(store, query, conceptEmbedder);
    expect(hits[0]?.record.title).toBe("Schema migrations");
  });

  it("blends in the lexical signal so an exact-term query still wins", async () => {
    // "pipeline" is an exact term in the release memory AND a deploy concept.
    const hits = await semanticSearchMemories(store, "pipeline", conceptEmbedder);
    expect(hits[0]?.record.title).toBe("Release pipeline");
  });

  it("falls back to lexical ranking when the embedder throws", async () => {
    const brokenEmbedder: Embedder = {
      async embed() {
        throw new Error("model unavailable");
      },
    };
    const hits = await semanticSearchMemories(store, "oauth token", brokenEmbedder);
    // Lexical still finds the credentials memory via the shared "oauth"/"token" terms.
    expect(hits[0]?.record.title).toBe("Login credentials");
  });

  it("returns nothing for an empty query", async () => {
    expect(await semanticSearchMemories(store, "   ", conceptEmbedder)).toHaveLength(0);
  });
});
