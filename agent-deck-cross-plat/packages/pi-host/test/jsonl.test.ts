import { describe, expect, it } from "vitest";
import { createJsonlReader, serializeJsonLine } from "../src/jsonl.ts";

function collect(): { lines: string[]; onLine: (line: string) => void } {
  const lines: string[] = [];
  return { lines, onLine: (line) => lines.push(line) };
}

describe("createJsonlReader", () => {
  it("emits complete lines from a single chunk", () => {
    const { lines, onLine } = collect();
    const reader = createJsonlReader(onLine);
    reader.push('{"a":1}\n{"b":2}\n');
    expect(lines).toEqual(['{"a":1}', '{"b":2}']);
  });

  it("buffers records split across chunks", () => {
    const { lines, onLine } = collect();
    const reader = createJsonlReader(onLine);
    reader.push('{"type":"text_de');
    reader.push('lta","delta":"hi"}\n');
    expect(lines).toEqual(['{"type":"text_delta","delta":"hi"}']);
  });

  it("strips a single trailing CR (CRLF tolerance)", () => {
    const { lines, onLine } = collect();
    const reader = createJsonlReader(onLine);
    reader.push('{"a":1}\r\n');
    expect(lines).toEqual(['{"a":1}']);
  });

  it("does NOT split on U+2028/U+2029 inside JSON strings", () => {
    const { lines, onLine } = collect();
    const reader = createJsonlReader(onLine);
    const record = JSON.stringify({ text: "line sep end" });
    reader.push(`${record}\n`);
    expect(lines).toEqual([record]);
    expect(JSON.parse(lines[0]!)).toEqual({ text: "line sep end" });
  });

  it("handles multibyte UTF-8 characters split across chunk boundaries", () => {
    const { lines, onLine } = collect();
    const reader = createJsonlReader(onLine);
    const record = Buffer.from(`${JSON.stringify({ text: "héllo 🎉" })}\n`, "utf8");
    // Split in the middle of the 4-byte emoji.
    const splitAt = record.indexOf(Buffer.from("🎉", "utf8")[0]!) + 2;
    reader.push(record.subarray(0, splitAt));
    reader.push(record.subarray(splitAt));
    expect(JSON.parse(lines[0]!)).toEqual({ text: "héllo 🎉" });
  });

  it("flushes an unterminated trailing line on end()", () => {
    const { lines, onLine } = collect();
    const reader = createJsonlReader(onLine);
    reader.push('{"a":1}');
    expect(lines).toEqual([]);
    reader.end();
    expect(lines).toEqual(['{"a":1}']);
  });
});

describe("serializeJsonLine", () => {
  it("appends exactly one LF", () => {
    expect(serializeJsonLine({ a: 1 })).toBe('{"a":1}\n');
  });
});
