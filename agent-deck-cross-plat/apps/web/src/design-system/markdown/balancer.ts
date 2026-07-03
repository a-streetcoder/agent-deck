/**
 * Streaming-markdown balancer.
 *
 * Pure function port of `StreamingMarkdownBalancer` in the macOS app
 * (PiAgentTranscriptNativeChrome.swift area / MarkdownViews.swift).
 *
 * Applied per streaming flush so that a half-typed source renders
 * cleanly without flickering malformed:
 *
 *   1. Splits the source on triple-backtick fences. If the trailing
 *      segment is inside an open fence (odd count of ```), leave the
 *      tail unchanged — the renderer keeps it as code.
 *   2. For the trailing outside-fence paragraph:
 *      a. Strip a bare trailing list-marker line (`-`, `*`, `+`, `N.`,
 *         `N)`) optionally followed by whitespace, so the bullet does
 *         not appear before any text follows.
 *      b. Strip a freshly-opened trailing `*`, `**`, or `` ` `` run of
 *         length 1 or 2 at a word boundary (no half-typed emphasis open).
 *   3. Close any odd-count `` ` `` by appending a matching `` ` ``.
 *   4. Close any odd-count `**` by appending a matching `**`.
 *   5. Restore the original trailing whitespace verbatim.
 */

/** Count occurrences of a substring in text. */
function countOf(text: string, needle: string): number {
  if (!needle) return 0;
  let count = 0;
  let idx = 0;
  while (true) {
    const next = text.indexOf(needle, idx);
    if (next === -1) return count;
    count += 1;
    idx = next + needle.length;
  }
}

/** Number of `**` pairs (greedy left-to-right scan, non-overlapping). */
function doubleAsteriskCount(text: string): number {
  let count = 0;
  let i = 0;
  while (i < text.length - 1) {
    if (text[i] === "*" && text[i + 1] === "*") {
      count += 1;
      i += 2;
    } else {
      i += 1;
    }
  }
  return count;
}

/**
 * Return the trailing whitespace run of `text` (may be empty).
 */
function trailingWhitespace(text: string): string {
  let i = text.length;
  while (i > 0 && /\s/.test(text[i - 1]!)) {
    i -= 1;
  }
  return text.slice(i);
}

/**
 * Strip an incomplete trailing list-marker line from the very end of
 * `text`. Returns the new text (possibly unchanged).
 *
 * Matches one of: `- `, `* `, `+ `, `N.`, `N)` (with optional trailing
 * whitespace) as the LAST line. The marker line must follow a newline
 * boundary or be the entire body.
 */
function stripIncompleteTrailingListMarkerLine(text: string): string {
  // Find the start of the last line.
  const lastNl = text.lastIndexOf("\n");
  const lineStart = lastNl + 1; // 0 when text has no newline
  const lastLine = text.slice(lineStart);

  // Bullet markers (`-`, `*`, `+`) followed by optional space only.
  // The line is incomplete when it contains the marker and nothing
  // else of substance (just whitespace).
  if (/^[-*+](\s*)$/.test(lastLine)) {
    return text.slice(0, lineStart);
  }
  // Ordered markers `N.` or `N)` followed by optional whitespace only.
  if (/^\d+[.)](\s*)$/.test(lastLine)) {
    return text.slice(0, lineStart);
  }
  return text;
}

/**
 * Strip a freshly-opened trailing emphasis/code marker that cannot yet
 * be parsed as anything meaningful (`*`, `**`, `` ` ``). The marker
 * must be at the end after any trailing whitespace is preserved
 * separately by the caller.
 *
 * Operates on text whose trailing whitespace has already been removed.
 */
function stripFreshlyOpenedTrailingMarker(text: string): string {
  if (text.length === 0) return text;

  // Trailing single or double `*` at a word/whitespace boundary.
  // We strip up to 2 asterisks; any longer run is preserved.
  const trailingStars = text.match(/(\*{1,2})$/);
  if (trailingStars) {
    const stars = trailingStars[1]!;
    const before = text.slice(0, text.length - stars.length);
    // Only strip when the character before is a boundary (whitespace,
    // empty, or a punctuation-ish boundary).
    if (before.length === 0 || /\s/.test(before[before.length - 1]!)) {
      return before;
    }
  }

  // Trailing single backtick at a word/whitespace boundary.
  if (text.endsWith("`")) {
    const before = text.slice(0, text.length - 1);
    if (before.length === 0 || /\s/.test(before[before.length - 1]!)) {
      return before;
    }
  }

  return text;
}

/**
 * Balance the trailing paragraph (outside any open fence) by stripping
 * half-typed open markers and then closing unbalanced inline tokens.
 *
 * Preserves the original trailing whitespace exactly.
 */
function balanceTrailingParagraph(segment: string): string {
  // (a) strip an incomplete trailing list-marker line FIRST so its own
  //     trailing whitespace (the space after `- `) is not preserved as
  //     part of the paragraph's trailing-whitespace run.
  const afterListStrip = stripIncompleteTrailingListMarkerLine(segment);
  const strippedListMarker = afterListStrip.length !== segment.length;

  // After list-marker strip the result is the new segment.
  const working = afterListStrip;

  // Now separate the trailing whitespace of the (possibly-shortened)
  // segment so we can restore it verbatim after balancing.
  const tail = strippedListMarker ? "" : trailingWhitespace(working);
  let body = tail.length > 0 ? working.slice(0, working.length - tail.length) : working;

  // (b) strip a freshly-opened trailing marker.
  body = stripFreshlyOpenedTrailingMarker(body);

  // (c) close unbalanced inline tokens.
  const tickCount = countOf(body, "`");
  if (tickCount % 2 === 1) {
    body += "`";
  }
  const starPairs = doubleAsteriskCount(body);
  if (starPairs % 2 === 1) {
    body += "**";
  }

  return body + tail;
}

/**
 * Balance a streaming-markdown source.
 *
 * Pure function: same input always yields the same output. Designed to
 * be cheap enough to run on every streaming flush.
 */
export function balance(text: string): string {
  if (text.length === 0) return text;

  // Split on triple-backtick fences. parts.length even => inside an
  // open fence at the tail; odd => last segment is outside a fence.
  const parts = text.split("```");
  if (parts.length === 1) {
    // No fences anywhere; balance the whole thing as one paragraph.
    return balanceTrailingParagraph(text);
  }

  const insideOpenFence = parts.length % 2 === 0;
  if (insideOpenFence) {
    // Trailing content is in-fence: leave it alone (consumer renders
    // the open code-block placeholder).
    return text;
  }

  // Find the start of the last paragraph in the trailing outside
  // segment. Rebalance only that paragraph; everything earlier in
  // `text` is unchanged.
  const lastSegment = parts[parts.length - 1]!;
  const head = parts.slice(0, -1).join("```") + "```";

  const paraBreak = lastSegment.lastIndexOf("\n\n");
  if (paraBreak === -1) {
    return head + balanceTrailingParagraph(lastSegment);
  }

  const preserved = lastSegment.slice(0, paraBreak + 2);
  const trailing = lastSegment.slice(paraBreak + 2);
  return head + preserved + balanceTrailingParagraph(trailing);
}
