import type { DiffLine } from "./unifiedDiff.ts";

/**
 * Review comments on diff lines (Slice 12), pattern-ported from t3code's
 * `apps/web/src/reviewCommentContext.ts` (MIT). A pending comment anchors to
 * one rendered diff row — file + line number + side (a deletion anchors to the
 * OLD file's numbering, everything else to the NEW file's; the donor's
 * `getDiffReviewSelectionPoint` rule) — and serializes into the outgoing
 * prompt as the donor's `<review_comment …>` block: escaped attributes, the
 * comment text, then a diff fence holding a synthesized single-line hunk.
 *
 * The whole feature is CLIENT-side, matching the donor: their server `review/`
 * dir only computes diff previews (our Slice-9 engine); serialization into the
 * prompt happens in the web app at send time (`appendReviewCommentsToPrompt`
 * in their ChatView), and the pending set is composer state. Ours lives in the
 * zustand store keyed by session id — sets stay separate across session
 * switches and die with the page (we deliberately skip the donor's
 * localStorage draft persistence; pending comments are short-lived review
 * context, not durable drafts).
 */

export type ReviewCommentSide = "old" | "new";

export interface PendingReviewComment {
  readonly id: string;
  readonly filePath: string;
  /** Which file's numbering `line` refers to (donor SelectionSide). */
  readonly side: ReviewCommentSide;
  /** 1-based line number on `side`. */
  readonly line: number;
  /** Index of the anchored row among the patch's CONTENT rows (add/del/
   * context, hunk headers excluded) — the donor's startIndex/endIndex
   * semantics over its diff-review lines. */
  readonly rowIndex: number;
  /** The donor's range label, e.g. "+42", "-7" or "13" (context). */
  readonly rangeLabel: string;
  /** The user's comment body. */
  readonly text: string;
  /** Donor-shaped excerpt: a synthesized `@@` hunk header + the marker line. */
  readonly diff: string;
}

function escapeReviewCommentAttribute(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

/** Donor `formatReviewCommentFence`: widen the fence past any backtick run. */
export function formatReviewCommentFence(language: string, contents: string): string {
  const longestBacktickRun = Math.max(
    0,
    ...Array.from(contents.matchAll(/`+/g), (match) => match[0].length),
  );
  const fence = "`".repeat(Math.max(3, longestBacktickRun + 1));
  return [`${fence}${language}`, contents.trimEnd(), fence].join("\n");
}

/** Donor `formatReviewCommentContext`: one serialized `<review_comment>` block.
 *
 * `sectionId`/`sectionTitle` are the SCOPE-level values the donor emits for the
 * working-tree diff (DiffPanel.tsx: `reviewSectionId = selectedGitScope`, the
 * literal `"unstaged"`; title `"Working tree"`) — NOT per-file. pi was tuned on
 * this exact shape, so we match it verbatim rather than baking in the path.
 * The comment body (`comment.text`) is placed verbatim, byte-faithful to the
 * donor (which also does not escape it — a body containing `</review_comment>`
 * is a known donor limitation, not worth diverging the pi-tuned format over).
 */
export function formatReviewComment(comment: PendingReviewComment): string {
  return [
    [
      "<review_comment",
      ` sectionId="unstaged"`,
      ` sectionTitle="Working tree"`,
      ` filePath="${escapeReviewCommentAttribute(comment.filePath)}"`,
      ` startIndex="${comment.rowIndex}"`,
      ` endIndex="${comment.rowIndex}"`,
      ` rangeLabel="${escapeReviewCommentAttribute(comment.rangeLabel)}"`,
      ">",
    ].join(""),
    comment.text.trim(),
    formatReviewCommentFence("diff", comment.diff),
    "</review_comment>",
  ].join("\n");
}

/**
 * Donor `appendReviewCommentsToPrompt`, verbatim semantics: blocks joined by
 * blank lines, appended after the trimmed prompt (or standing alone when the
 * composer text is empty).
 */
export function appendReviewCommentsToPrompt(
  prompt: string,
  comments: readonly PendingReviewComment[],
): string {
  const blocks = comments.map(formatReviewComment);
  if (blocks.length === 0) return prompt;
  const trimmedPrompt = prompt.trim();
  return trimmedPrompt.length > 0
    ? `${trimmedPrompt}\n\n${blocks.join("\n\n")}`
    : blocks.join("\n\n");
}

const COMMENTABLE_KINDS = new Set<DiffLine["kind"]>(["add", "del", "context"]);

/** Whether a rendered diff row can carry a comment (content rows only). */
export function isCommentableLine(line: DiffLine): boolean {
  return COMMENTABLE_KINDS.has(line.kind);
}

function changeMarker(kind: DiffLine["kind"]): string {
  if (kind === "add") return "+";
  if (kind === "del") return "-";
  return " ";
}

/**
 * Build a pending comment anchored to `lines[lineIndex]` (donor
 * `buildDiffReviewComment`, collapsed to a single-row range). Returns null for
 * non-content rows.
 */
export function buildLineReviewComment(input: {
  id: string;
  filePath: string;
  lines: readonly DiffLine[];
  lineIndex: number;
  text: string;
}): PendingReviewComment | null {
  const row = input.lines[input.lineIndex];
  if (row === undefined || !isCommentableLine(row)) return null;

  // The donor's selection-point rule: a deletion anchors old-side; everything
  // else anchors to its new-side number.
  const side: ReviewCommentSide = row.kind === "del" ? "old" : "new";
  const line = side === "old" ? row.oldLine : row.newLine;
  if (line === null) return null;

  // startIndex/endIndex count CONTENT rows only (the donor's diff-review lines
  // carry no hunk headers or meta rows).
  const rowIndex = input.lines
    .slice(0, input.lineIndex)
    .filter((candidate) => isCommentableLine(candidate)).length;

  const marker = changeMarker(row.kind);
  const oldRange = row.oldLine !== null ? { start: row.oldLine, count: 1 } : { start: 0, count: 0 };
  const newRange = row.newLine !== null ? { start: row.newLine, count: 1 } : { start: 0, count: 0 };
  // Row text includes its +/-/space prefix; the excerpt re-derives it so a
  // context row's leading space is never doubled.
  const content = row.text.slice(1);

  return {
    id: input.id,
    filePath: input.filePath,
    side,
    line,
    rowIndex,
    // Donor `formatDiffReviewRangeLabel` for a single line: marker + number
    // (context's space marker trims to nothing).
    rangeLabel: `${marker.trim()}${line}`,
    text: input.text.trim(),
    diff: [
      `@@ -${oldRange.start},${oldRange.count} +${newRange.start},${newRange.count} @@`,
      `${marker}${content}`,
    ].join("\n"),
  };
}

/**
 * Find the rendered row a pending comment anchors to in a (possibly
 * refreshed) patch — matched by side + line number, never the captured index,
 * so an unrelated edit above the anchor doesn't detach it. Returns -1 when
 * the anchored line no longer exists in the patch (the comment still rides
 * the composer; it just has no inline home).
 */
export function findAnchoredLineIndex(
  lines: readonly DiffLine[],
  comment: Pick<PendingReviewComment, "side" | "line">,
): number {
  return lines.findIndex((row) =>
    comment.side === "old"
      ? row.kind === "del" && row.oldLine === comment.line
      : row.kind !== "del" && row.newLine === comment.line,
  );
}
