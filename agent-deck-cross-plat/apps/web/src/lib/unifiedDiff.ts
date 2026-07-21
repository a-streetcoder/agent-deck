/**
 * Unified-diff parsing for the diff panel (Slice 10).
 *
 * MAIN-THREAD RATIONALE (vs the donor's worker pool): t3code renders diffs
 * through `@pierre/diffs`, whose expensive step is shiki AST syntax
 * highlighting — that is what its worker pool keeps off the main thread. Our
 * panel renders line-type coloring only (no tokenization), and the server caps
 * every patch at DIFF_MAX_PATCH_CHARS (200k chars — see contracts/src/diff.ts),
 * so parsing is one linear split+classify pass over ≤200k chars: well under a
 * frame even on slow hardware. Rendering stays smooth on a max-size patch
 * because the row list is virtualized (react-virtuoso in DiffPanel), keeping
 * the DOM at viewport size regardless of patch length. If a later slice adds
 * syntax highlighting, that is the point to revisit a worker.
 */

export type DiffLineKind = "meta" | "hunk" | "add" | "del" | "context";

export interface DiffLine {
  kind: DiffLineKind;
  /** The full line, including its +/-/space/@@ prefix. */
  text: string;
  /** 1-based line number in the OLD file (context/del lines). */
  oldLine: number | null;
  /** 1-based line number in the NEW file (context/add lines). */
  newLine: number | null;
}

const HUNK_HEADER = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/;

/**
 * Parse one file's unified diff into renderable lines with old/new line
 * numbers. Tolerant: anything before the first hunk (diff --git/index/---/+++)
 * classifies as `meta`, and a malformed hunk header falls back to `meta` too —
 * the panel never throws on server output.
 */
export function parseUnifiedDiff(patch: string): DiffLine[] {
  // A trailing newline would otherwise render a phantom empty context row.
  const raw = patch.endsWith("\n") ? patch.slice(0, -1) : patch;
  if (raw.length === 0) return [];
  const lines = raw.split("\n");
  const out: DiffLine[] = [];
  let oldLine = 0;
  let newLine = 0;
  let inHunk = false;

  for (const text of lines) {
    const hunk = HUNK_HEADER.exec(text);
    if (hunk) {
      oldLine = Number.parseInt(hunk[1]!, 10);
      newLine = Number.parseInt(hunk[2]!, 10);
      inHunk = true;
      out.push({ kind: "hunk", text, oldLine: null, newLine: null });
      continue;
    }
    if (!inHunk) {
      out.push({ kind: "meta", text, oldLine: null, newLine: null });
      continue;
    }
    if (text.startsWith("+")) {
      out.push({ kind: "add", text, oldLine: null, newLine: newLine++ });
    } else if (text.startsWith("-")) {
      out.push({ kind: "del", text, oldLine: oldLine++, newLine: null });
    } else if (text.startsWith("\\")) {
      // "\ No newline at end of file" — annotates the previous line.
      out.push({ kind: "meta", text, oldLine: null, newLine: null });
    } else {
      out.push({ kind: "context", text, oldLine: oldLine++, newLine: newLine++ });
    }
  }
  return out;
}
