/**
 * Semantic recall math (native AgentMemoryEmbedder). Native uses Apple's
 * on-device NLContextualEmbedding — which is macOS-only — so the cross-platform
 * port substitutes a pluggable JS Embedder but keeps native's key trick:
 * MEAN-CENTERED cosine. Raw mean-pooled embeddings are anisotropic (everything
 * clusters near ~0.9 cosine); subtracting the corpus centroid from the query and
 * every doc spreads cosine back into a usable range. The Embedder is injected so
 * this scoring is unit-testable with stub vectors, no model download.
 */

export interface Embedder {
  /** Embed each text to a fixed-dimension vector (all vectors the same length). */
  embed(texts: string[]): Promise<number[][]>;
}

/** Cosine similarity of two equal-length vectors; 0 for a zero vector. */
export function cosineSimilarity(a: number[], b: number[]): number {
  let dot = 0;
  let normA = 0;
  let normB = 0;
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i += 1) {
    dot += a[i]! * b[i]!;
    normA += a[i]! * a[i]!;
    normB += b[i]! * b[i]!;
  }
  if (normA === 0 || normB === 0) return 0;
  return dot / (Math.sqrt(normA) * Math.sqrt(normB));
}

/** Subtract the centroid of `vectors` from each — native's mean-centering step. */
export function meanCenter(vectors: number[][]): number[][] {
  if (vectors.length === 0) return [];
  const dim = vectors[0]!.length;
  const centroid = new Array<number>(dim).fill(0);
  for (const v of vectors) {
    for (let i = 0; i < dim; i += 1) centroid[i]! += v[i] ?? 0;
  }
  for (let i = 0; i < dim; i += 1) centroid[i]! /= vectors.length;
  // `?? 0` keeps a ragged vector (a misbehaving embedder) from producing NaN
  // in dimensions past the first vector's length.
  return vectors.map((v) => v.map((x, i) => x - (centroid[i] ?? 0)));
}

/**
 * Centered cosine of the query against each doc: center the query + docs
 * together, then cosine the centered query against each centered doc. Returns a
 * score per doc in the same order.
 */
export function centeredCosineScores(queryVec: number[], docVecs: number[][]): number[] {
  if (docVecs.length === 0) return [];
  const centered = meanCenter([queryVec, ...docVecs]);
  const centeredQuery = centered[0]!;
  return centered.slice(1).map((doc) => cosineSimilarity(centeredQuery, doc));
}
