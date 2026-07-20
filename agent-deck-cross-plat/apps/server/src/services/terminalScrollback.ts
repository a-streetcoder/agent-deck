/**
 * Scrollback sanitization for terminal history replay (Slice 8), lifted
 * near-verbatim from t3code's `apps/server/src/terminal/Manager.ts`
 * (`sanitizeTerminalHistoryChunk` + helpers, MIT).
 *
 * Why this exists: the PTY stream contains terminal QUERY/REPORT escape
 * sequences — CSI DSR queries (`ESC[6n`), CPR replies (`ESC[<r>;<c>R`),
 * Device Attributes (`ESC[c`, `ESC[>c` and their replies), and OSC 10/11/12
 * color queries/replies. A LIVE xterm.js answers those on arrival, which is
 * correct — but if they are buffered into scrollback and REPLAYED on
 * reattach, xterm re-answers them and the answer bytes are typed into the
 * live shell as stray input (`ESC[24;1R` garbage at the prompt). Windows
 * ConPTY emits `ESC[6n` during its startup handshake, so every reattach
 * would hit this. The donor's fix, kept here: strip exactly those sequences
 * from the HISTORY buffer while the live stream stays untouched.
 *
 * The scanner is resumable: a chunk may end mid-sequence, so the
 * unterminated tail is returned as `pendingControlSequence` and must be
 * prepended to the next chunk by the caller.
 */

function isCsiFinalByte(codePoint: number): boolean {
  return codePoint >= 0x40 && codePoint <= 0x7e;
}

/** CSI sequences to strip: DSR queries (`n`), CPR replies (`R`), DA (`c`). */
function shouldStripCsiSequence(body: string, finalByte: string): boolean {
  if (finalByte === "n") {
    return true;
  }
  if (finalByte === "R" && /^[0-9;?]*$/.test(body)) {
    return true;
  }
  if (finalByte === "c" && /^[>0-9;?]*$/.test(body)) {
    return true;
  }
  return false;
}

/** OSC sequences to strip: 10/11/12 (fg/bg/cursor color) queries + replies. */
function shouldStripOscSequence(content: string): boolean {
  return /^(10|11|12);(?:\?|rgb:)/.test(content);
}

function stripStringTerminator(value: string): string {
  if (value.endsWith("\u001b\\")) {
    return value.slice(0, -2);
  }
  const lastCharacter = value.at(-1);
  if (lastCharacter === "\u0007" || lastCharacter === "\u009c") {
    return value.slice(0, -1);
  }
  return value;
}

function findStringTerminatorIndex(input: string, start: number): number | null {
  for (let index = start; index < input.length; index += 1) {
    const codePoint = input.charCodeAt(index);
    if (codePoint === 0x07 || codePoint === 0x9c) {
      return index + 1;
    }
    if (codePoint === 0x1b && input.charCodeAt(index + 1) === 0x5c) {
      return index + 2;
    }
  }
  return null;
}

function isEscapeIntermediateByte(codePoint: number): boolean {
  return codePoint >= 0x20 && codePoint <= 0x2f;
}

function isEscapeFinalByte(codePoint: number): boolean {
  return codePoint >= 0x30 && codePoint <= 0x7e;
}

function findEscapeSequenceEndIndex(input: string, start: number): number | null {
  let cursor = start;
  while (cursor < input.length && isEscapeIntermediateByte(input.charCodeAt(cursor))) {
    cursor += 1;
  }
  if (cursor >= input.length) {
    return null;
  }
  return isEscapeFinalByte(input.charCodeAt(cursor)) ? cursor + 1 : start + 1;
}

/**
 * Scan one raw PTY chunk (prefixed by the previous chunk's unterminated
 * control-sequence tail) and return the history-safe text plus the new
 * unterminated tail. All escape sequences EXCEPT the query/report family
 * (see module doc) pass through unchanged, so replayed history still renders
 * colors, cursor motion, and screen clears faithfully.
 */
export function sanitizeTerminalHistoryChunk(
  pendingControlSequence: string,
  data: string,
): { visibleText: string; pendingControlSequence: string } {
  const input = `${pendingControlSequence}${data}`;
  let visibleText = "";
  let index = 0;

  const append = (value: string): void => {
    visibleText += value;
  };

  while (index < input.length) {
    const codePoint = input.charCodeAt(index);

    if (codePoint === 0x1b) {
      const nextCodePoint = input.charCodeAt(index + 1);
      if (Number.isNaN(nextCodePoint)) {
        return { visibleText, pendingControlSequence: input.slice(index) };
      }

      // ESC [ — CSI sequence.
      if (nextCodePoint === 0x5b) {
        let cursor = index + 2;
        while (cursor < input.length) {
          if (isCsiFinalByte(input.charCodeAt(cursor))) {
            const sequence = input.slice(index, cursor + 1);
            const body = input.slice(index + 2, cursor);
            if (!shouldStripCsiSequence(body, input[cursor] ?? "")) {
              append(sequence);
            }
            index = cursor + 1;
            break;
          }
          cursor += 1;
        }
        if (cursor >= input.length) {
          return { visibleText, pendingControlSequence: input.slice(index) };
        }
        continue;
      }

      // ESC ] / P / ^ / _ — OSC, DCS, PM, APC: string sequences up to ST/BEL.
      if (
        nextCodePoint === 0x5d ||
        nextCodePoint === 0x50 ||
        nextCodePoint === 0x5e ||
        nextCodePoint === 0x5f
      ) {
        const terminatorIndex = findStringTerminatorIndex(input, index + 2);
        if (terminatorIndex === null) {
          return { visibleText, pendingControlSequence: input.slice(index) };
        }
        const sequence = input.slice(index, terminatorIndex);
        const content = stripStringTerminator(input.slice(index + 2, terminatorIndex));
        if (nextCodePoint !== 0x5d || !shouldStripOscSequence(content)) {
          append(sequence);
        }
        index = terminatorIndex;
        continue;
      }

      // Other ESC sequences (charset selects, keypad modes, …): pass through.
      const escapeSequenceEndIndex = findEscapeSequenceEndIndex(input, index + 1);
      if (escapeSequenceEndIndex === null) {
        return { visibleText, pendingControlSequence: input.slice(index) };
      }
      append(input.slice(index, escapeSequenceEndIndex));
      index = escapeSequenceEndIndex;
      continue;
    }

    // C1 CSI (0x9b) — same handling as ESC [.
    if (codePoint === 0x9b) {
      let cursor = index + 1;
      while (cursor < input.length) {
        if (isCsiFinalByte(input.charCodeAt(cursor))) {
          const sequence = input.slice(index, cursor + 1);
          const body = input.slice(index + 1, cursor);
          if (!shouldStripCsiSequence(body, input[cursor] ?? "")) {
            append(sequence);
          }
          index = cursor + 1;
          break;
        }
        cursor += 1;
      }
      if (cursor >= input.length) {
        return { visibleText, pendingControlSequence: input.slice(index) };
      }
      continue;
    }

    // C1 OSC/DCS/PM/APC (0x9d / 0x90 / 0x9e / 0x9f).
    if (codePoint === 0x9d || codePoint === 0x90 || codePoint === 0x9e || codePoint === 0x9f) {
      const terminatorIndex = findStringTerminatorIndex(input, index + 1);
      if (terminatorIndex === null) {
        return { visibleText, pendingControlSequence: input.slice(index) };
      }
      const sequence = input.slice(index, terminatorIndex);
      const content = stripStringTerminator(input.slice(index + 1, terminatorIndex));
      if (codePoint !== 0x9d || !shouldStripOscSequence(content)) {
        append(sequence);
      }
      index = terminatorIndex;
      continue;
    }

    append(input[index] ?? "");
    index += 1;
  }

  return { visibleText, pendingControlSequence: "" };
}
