import type { Embedder } from "./semantic.ts";

/**
 * The optional on-device embedder for semantic recall (native AgentMemoryEmbedder
 * used Apple's NLContextualEmbedding; the cross-platform stand-in is a small
 * transformer). Lexical+fuzzy recall is the always-on default — this is opt-in.
 *
 * The model library is NOT a declared dependency: it's loaded by a LAZY dynamic
 * import via a runtime specifier, so the base install and CI stay lightweight
 * (no ONNX native binary, no first-run model download) and only someone who opts
 * in installs it. If it's missing, a clear "install it" error is thrown and the
 * caller falls back to lexical recall.
 */

/** The slice of @huggingface/transformers this adapter uses (kept minimal so an
 *  absent dependency is a runtime concern, never a compile-time one). */
interface FeatureExtractionOutput {
  tolist(): number[][];
}
type FeatureExtractionPipeline = (
  texts: string[],
  options: { pooling: "mean"; normalize: boolean },
) => Promise<FeatureExtractionOutput>;
interface TransformersModule {
  pipeline(task: "feature-extraction", model: string): Promise<FeatureExtractionPipeline>;
}

/** Thrown when the optional embedder package isn't installed — distinct from a
 *  transient model-init failure, so callers can permanently fall back to lexical
 *  for a missing dep while still retrying a transient one. */
export class EmbedderUnavailableError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "EmbedderUnavailableError";
  }
}

/** all-MiniLM-L6-v2: 384-dim, ~small; its outputs are mean-pooled + L2-normalized
 *  so the mean-centered cosine in semantic.ts behaves (unit-norm inputs). */
const DEFAULT_MODEL = "Xenova/all-MiniLM-L6-v2";
const PACKAGE = "@huggingface/transformers";

/**
 * Build the on-device embedder. Loads the model once (the returned Embedder
 * reuses the pipeline). Throws a clear, actionable error if the optional package
 * isn't installed — callers treat that as "semantic unavailable → lexical".
 */
export async function createOnDeviceEmbedder(options: { model?: string } = {}): Promise<Embedder> {
  // A `string`-typed specifier keeps TypeScript/bundlers from statically resolving
  // the (uninstalled, optional) package — it's a pure runtime import.
  const specifier: string = PACKAGE;
  let mod: TransformersModule;
  try {
    mod = (await import(specifier)) as unknown as TransformersModule;
  } catch {
    throw new EmbedderUnavailableError(
      `Semantic memory needs the optional '${PACKAGE}' package. Install it (e.g. \`pnpm add ${PACKAGE}\`) and set AGENT_DECK_SEMANTIC_MEMORY=1; recall stays lexical until then.`,
    );
  }
  const extractor = await mod.pipeline("feature-extraction", options.model ?? DEFAULT_MODEL);
  return {
    async embed(texts) {
      if (texts.length === 0) return [];
      const output = await extractor(texts, { pooling: "mean", normalize: true });
      return output.tolist();
    },
  };
}
