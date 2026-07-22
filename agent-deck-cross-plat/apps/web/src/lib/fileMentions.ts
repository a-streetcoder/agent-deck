/**
 * Slice 17 — file tag chips.
 *
 * The composer's `@`-file autocomplete (useSuggestions) inserts a mention as the
 * literal token `@<path> ` into the draft text, and that literal token is what
 * rides the prompt to pi (existing behavior, unchanged). This module derives the
 * removable *chips* the composer shows for those mentions purely from the draft
 * string, and computes the draft after a chip is removed — so the chip row is a
 * view over the text, never a second source of truth.
 *
 * A mention is an `@` that starts the string or follows whitespace, then a run of
 * non-whitespace path characters (mirrors useSuggestions' `detectTrigger`). The
 * accept path always appends a trailing space, so a completed mention is
 * whitespace- or end-terminated in practice; we tokenize on the same boundary.
 */

export interface FileMention {
  /** The mentioned path (the text after `@`, no leading `@`). */
  path: string;
  /** Index of the `@` in the draft. */
  start: number;
  /** Index one past the last path char (exclusive). */
  end: number;
}

// `@` at string start or after whitespace, capturing a non-whitespace path run.
// The lookbehind-free form: match the optional preceding boundary separately.
const MENTION = /(^|\s)@(\S+)/g;

/**
 * All `@path` mentions in the draft, in order of appearance. Deliberately returns
 * one entry per occurrence (a path mentioned twice yields two chips), matching the
 * text: removing one chip removes one token.
 */
export function parseFileMentions(draft: string): FileMention[] {
  const mentions: FileMention[] = [];
  MENTION.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = MENTION.exec(draft)) !== null) {
    const lead = match[1] ?? "";
    const path = match[2] ?? "";
    if (path.length === 0) continue;
    const start = match.index + lead.length; // index of the `@`
    mentions.push({ path, start, end: start + 1 + path.length });
  }
  return mentions;
}

/**
 * Remove the mention token at the given `@` index, returning the new draft.
 * Collapses one adjacent separator so removing a chip doesn't leave a double
 * space or a leading space; leaves the caret-neutral text otherwise untouched.
 * If no mention starts at `start`, the draft is returned unchanged.
 */
export function removeFileMention(draft: string, start: number): string {
  const mention = parseFileMentions(draft).find((m) => m.start === start);
  if (!mention) return draft;
  const before = draft.slice(0, mention.start);
  let after = draft.slice(mention.end);
  // Eat exactly one trailing space (the accept path adds one) so we don't leave a
  // gap; otherwise, if the token was at the very start, eat one leading space from
  // `after` to avoid a leading space.
  if (after.startsWith(" ")) {
    after = after.slice(1);
  } else if (before.endsWith(" ") && after.length === 0) {
    return before.replace(/ $/, "");
  }
  return before + after;
}
