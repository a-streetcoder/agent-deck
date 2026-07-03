import { StringDecoder } from "node:string_decoder";

/**
 * Strict LF-only JSONL framing, mirroring pi's own framer (dist/modes/rpc/jsonl.js,
 * not exported through the package's exports map).
 *
 * Node readline is deliberately NOT used: it splits on Unicode separators such as
 * U+2028/U+2029 that are valid inside JSON strings. Records are split on `\n` only,
 * with a single trailing `\r` stripped.
 */

export function serializeJsonLine(value: unknown): string {
  return `${JSON.stringify(value)}\n`;
}

export interface JsonlReader {
  /** Feed a chunk of stdout data (Buffer or string). */
  push(chunk: Buffer | string): void;
  /** Flush any trailing, unterminated line (call on stream end). */
  end(): void;
}

export function createJsonlReader(onLine: (line: string) => void): JsonlReader {
  const decoder = new StringDecoder("utf8");
  let buffer = "";

  const emitLine = (line: string): void => {
    onLine(line.endsWith("\r") ? line.slice(0, -1) : line);
  };

  return {
    push(chunk) {
      buffer += typeof chunk === "string" ? chunk : decoder.write(chunk);
      while (true) {
        const newlineIndex = buffer.indexOf("\n");
        if (newlineIndex === -1) {
          return;
        }
        emitLine(buffer.slice(0, newlineIndex));
        buffer = buffer.slice(newlineIndex + 1);
      }
    },
    end() {
      buffer += decoder.end();
      if (buffer.length > 0) {
        emitLine(buffer);
        buffer = "";
      }
    },
  };
}
