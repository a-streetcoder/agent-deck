/**
 * Lexical matching primitives for recall and the near-duplicate guard. The
 * native app uses these as corrective evidence on top of on-device embeddings;
 * cross-platform, they are the primary signal until a JS embedder lands. Terms
 * are drawn from a memory's title + summary + tags (never the body — incidental
 * body vocabulary qualified junk in the native eval).
 */

const STOPWORDS = new Set([
  "a",
  "an",
  "the",
  "and",
  "or",
  "but",
  "if",
  "then",
  "else",
  "for",
  "of",
  "to",
  "in",
  "on",
  "at",
  "by",
  "with",
  "from",
  "as",
  "is",
  "are",
  "was",
  "were",
  "be",
  "been",
  "being",
  "it",
  "its",
  "this",
  "that",
  "these",
  "those",
  "we",
  "you",
  "they",
  "he",
  "she",
  "i",
  "our",
  "your",
  "their",
  "my",
  "me",
  "us",
  "them",
  "do",
  "does",
  "did",
  "have",
  "has",
  "had",
  "will",
  "would",
  "can",
  "could",
  "should",
  "may",
  "might",
  "must",
  "not",
  "no",
  "yes",
  "so",
  "than",
  "too",
  "very",
  "just",
  "how",
  "what",
  "when",
  "where",
  "which",
  "who",
  "why",
  "use",
  "using",
  "used",
  "into",
  "out",
  "up",
  "down",
  "over",
  "about",
  "via",
  "per",
  "there",
  "here",
  "get",
  "got",
]);

/** Collapse a doubled trailing consonant (runn→run, stopp→stop) after -ing/-ed. */
function collapseDouble(word: string): string {
  return word.length > 2 && /([bcdfghjklmnpqrstvwxz])\1$/.test(word) ? word.slice(0, -1) : word;
}

/** Light plural / -ing / -ed stemming so paraphrases still overlap. */
function stem(word: string): string {
  let w = word;
  if (w.length > 4 && w.endsWith("ing")) w = collapseDouble(w.slice(0, -3));
  else if (w.length > 4 && w.endsWith("ed")) w = collapseDouble(w.slice(0, -2));
  else if (w.length > 4 && w.endsWith("ies"))
    w = `${w.slice(0, -3)}y`; // parties -> party
  // Only true "+es" plurals (sibilant endings) drop "es"; "-se/-ze + s" words
  // like releases/sizes fall through to the simple -s strip below.
  else if (w.length > 4 && /(?:x|ch|sh)es$/.test(w))
    w = w.slice(0, -2); // boxes -> box, watches -> watch
  else if (w.length > 3 && w.endsWith("s") && !w.endsWith("ss")) w = w.slice(0, -1); // services -> service, releases -> release
  return w;
}

/**
 * Informative terms of a string: lowercased alphanumeric tokens, stopwords and
 * 1-char tokens dropped, lightly stemmed, de-duplicated. Order is not
 * significant — the result is a set.
 */
export function informativeTerms(text: string): Set<string> {
  const terms = new Set<string>();
  for (const raw of text.toLowerCase().split(/[^a-z0-9]+/)) {
    if (raw.length < 2) continue;
    if (STOPWORDS.has(raw)) continue;
    const stemmed = stem(raw);
    if (stemmed.length < 2) continue;
    terms.add(stemmed);
  }
  return terms;
}

/** Informative terms carried by a memory's retrieval fields (never the body). */
export function memoryTerms(fields: {
  title: string;
  summary: string;
  tags: string[];
}): Set<string> {
  return informativeTerms([fields.title, fields.summary, fields.tags.join(" ")].join(" "));
}

/** Terms present in both sets. */
export function sharedTerms(a: Set<string>, b: Set<string>): string[] {
  const out: string[] = [];
  for (const term of a) if (b.has(term)) out.push(term);
  return out;
}

/**
 * Only terms at least this long may fuzzy-match. Short words are excluded
 * because a single edit flips too many unrelated ones into each other
 * (cat/car, code/core, add/aid) — the false-positive rate isn't worth it.
 */
export const FUZZY_MIN_LEN = 5;

/**
 * True when `a` and `b` differ by at most one single-character edit
 * (substitution, insertion, or deletion). A linear one-pass check — no DP
 * matrix — that early-exits on a length gap > 1. Equal strings count as 0
 * edits (true); callers that only want genuine near-misses exclude exact
 * matches themselves.
 */
export function withinOneEdit(a: string, b: string): boolean {
  const la = a.length;
  const lb = b.length;
  if (Math.abs(la - lb) > 1) return false;
  // Skip the common prefix.
  let i = 0;
  while (i < la && i < lb && a[i] === b[i]) i++;
  if (i === la && i === lb) return true; // identical
  if (la === lb) return a.slice(i + 1) === b.slice(i + 1); // substitution
  if (la > lb) return a.slice(i + 1) === b.slice(i); // deletion from a
  return a.slice(i) === b.slice(i + 1); // insertion into a
}

/**
 * Query terms that are NOT an exact match but land within one edit of some
 * memory term, with both sides at least FUZZY_MIN_LEN — the typo / near-miss
 * signal ("postgress" → "postgres", "migation" → "migration"). Ranked BELOW
 * exact overlap by the caller; de-duplicated on the query side.
 */
export function fuzzyMatchedTerms(queryTerms: Set<string>, memTerms: Set<string>): string[] {
  const out: string[] = [];
  for (const q of queryTerms) {
    if (q.length < FUZZY_MIN_LEN || memTerms.has(q)) continue;
    for (const m of memTerms) {
      if (m.length < FUZZY_MIN_LEN) continue;
      if (withinOneEdit(q, m)) {
        out.push(q);
        break;
      }
    }
  }
  return out;
}

/**
 * Overlap coefficient |A∩B| / min(|A|,|B|) — the near-duplicate signal. It is 1
 * when one term set is a subset of the other, so it catches a re-write that
 * adds detail without changing the topic. Empty sets score 0.
 */
export function overlapCoefficient(a: Set<string>, b: Set<string>): number {
  if (a.size === 0 || b.size === 0) return 0;
  return sharedTerms(a, b).length / Math.min(a.size, b.size);
}
