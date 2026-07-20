import { describe, expect, it } from "vitest";
import { sanitizeTerminalHistoryChunk } from "../src/services/terminalScrollback.ts";

/**
 * Unit tests for the scrollback history sanitizer (ported from t3code's
 * Manager.ts, MIT): the query/report escape family must be stripped from
 * history — a replay would make xterm re-answer queries into the live shell —
 * while every other sequence (colors, cursor motion, titles) passes through.
 * Control bytes are built with fromCharCode so no literal escapes live in
 * this source file.
 */

const ESC = String.fromCharCode(0x1b);
const BEL = String.fromCharCode(0x07);
const CSI_C1 = String.fromCharCode(0x9b);
const OSC_C1 = String.fromCharCode(0x9d);
const ST_C1 = String.fromCharCode(0x9c);

function sanitizeAll(...chunks: string[]): string {
  let pending = "";
  let visible = "";
  for (const chunk of chunks) {
    const result = sanitizeTerminalHistoryChunk(pending, chunk);
    pending = result.pendingControlSequence;
    visible += result.visibleText;
  }
  return visible;
}

describe("sanitizeTerminalHistoryChunk", () => {
  it("strips DSR queries (CSI 6n) but keeps surrounding text", () => {
    expect(sanitizeAll(`a${ESC}[6nb`)).toBe("ab");
  });

  it("strips CPR replies (digits/; body ending in R)", () => {
    expect(sanitizeAll(`x${ESC}[24;80Ry`)).toBe("xy");
  });

  it("keeps a non-report CSI sequence ending in R-like finals only when it is a report", () => {
    // A CPR body may only contain digits/;/? — anything else ending in R stays.
    expect(sanitizeAll(`${ESC}[1mR`)).toBe(`${ESC}[1mR`);
  });

  it("strips Device Attributes queries and replies (final byte c)", () => {
    expect(sanitizeAll(`a${ESC}[cb`)).toBe("ab");
    expect(sanitizeAll(`a${ESC}[>0;276;0cb`)).toBe("ab");
  });

  it("keeps SGR/cursor sequences (colors, clears)", () => {
    const colored = `${ESC}[31mred${ESC}[0m`;
    expect(sanitizeAll(colored)).toBe(colored);
    const clear = `${ESC}[2J${ESC}[H`;
    expect(sanitizeAll(clear)).toBe(clear);
  });

  it("strips OSC 10/11/12 color queries and replies, with BEL or ST terminators", () => {
    expect(sanitizeAll(`a${ESC}]11;?${BEL}b`)).toBe("ab");
    expect(sanitizeAll(`a${ESC}]10;rgb:ffff/ffff/ffff${ESC}\\b`)).toBe("ab");
  });

  it("keeps other OSC sequences (window title)", () => {
    const title = `${ESC}]0;my title${BEL}`;
    expect(sanitizeAll(`${title}text`)).toBe(`${title}text`);
  });

  it("handles the C1 single-byte forms (CSI 0x9b, OSC 0x9d)", () => {
    expect(sanitizeAll(`a${CSI_C1}6nb`)).toBe("ab");
    expect(sanitizeAll(`a${OSC_C1}11;?${ST_C1}b`)).toBe("ab");
  });

  it("resumes a sequence split across chunks (pendingControlSequence)", () => {
    expect(sanitizeAll(`x${ESC}[24`, ";1Ry")).toBe("xy");
    expect(sanitizeAll(`x${ESC}`, "[6n", "y")).toBe("xy");
  });

  it("holds an unterminated tail as pending without emitting it", () => {
    const first = sanitizeTerminalHistoryChunk("", `ok${ESC}[3`);
    expect(first.visibleText).toBe("ok");
    expect(first.pendingControlSequence).toBe(`${ESC}[3`);
    const second = sanitizeTerminalHistoryChunk(first.pendingControlSequence, "1mz");
    expect(second.visibleText).toBe(`${ESC}[31mz`);
    expect(second.pendingControlSequence).toBe("");
  });

  it("passes plain ESC sequences through (keypad modes, charset selects)", () => {
    const keypad = `${ESC}=text${ESC}>`;
    expect(sanitizeAll(keypad)).toBe(keypad);
  });
});
