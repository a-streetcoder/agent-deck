import { describe, expect, it } from "vitest";
import {
  classifyPiLine,
  COMPACT_TIMEOUT_MS,
  createRequestIdSource,
  DEFAULT_REQUEST_TIMEOUT_MS,
} from "../src/rpcProtocol.ts";

/**
 * The shared JSONL wire-protocol helper (rpcProtocol.ts) — the ONE
 * classification decision tree consumed by both PiSession and the server's
 * PiHost Effect service. Behavior is pinned here so neither consumer can
 * drift: blank-skip, malformed surfacing, response-without-id drop, req-N ids,
 * and the legacy timeout constants.
 */

describe("classifyPiLine", () => {
  it("ignores blank lines", () => {
    expect(classifyPiLine("")).toEqual({ kind: "ignored", reason: "blank" });
    expect(classifyPiLine("   ")).toEqual({ kind: "ignored", reason: "blank" });
    expect(classifyPiLine("\t")).toEqual({ kind: "ignored", reason: "blank" });
  });

  it("classifies non-JSON as malformed, carrying the raw line", () => {
    expect(classifyPiLine("this is not json")).toEqual({
      kind: "malformed",
      line: "this is not json",
    });
  });

  it("classifies JSON without a type record shape as malformed", () => {
    expect(classifyPiLine("42")).toEqual({ kind: "malformed", line: "42" });
    expect(classifyPiLine('"str"')).toEqual({ kind: "malformed", line: '"str"' });
    expect(classifyPiLine("null")).toEqual({ kind: "malformed", line: "null" });
    expect(classifyPiLine("{}")).toEqual({ kind: "malformed", line: "{}" });
    expect(classifyPiLine('{"id":"req-0"}')).toEqual({
      kind: "malformed",
      line: '{"id":"req-0"}',
    });
  });

  it("classifies an addressed response as response", () => {
    const line = '{"type":"response","command":"get_state","id":"req-3","success":true,"data":{}}';
    const classified = classifyPiLine(line);
    expect(classified.kind).toBe("response");
    if (classified.kind === "response") {
      expect(classified.response.id).toBe("req-3");
      expect(classified.response.success).toBe(true);
    }
  });

  it("drops a response without an id (legacy silent-drop rule), never as event", () => {
    expect(classifyPiLine('{"type":"response","command":"get_state","success":true}')).toEqual({
      kind: "ignored",
      reason: "response-without-id",
    });
    expect(classifyPiLine('{"type":"response","command":"x","success":true,"id":""}')).toEqual({
      kind: "ignored",
      reason: "response-without-id",
    });
  });

  it("classifies every other typed record as an inbound event", () => {
    const classified = classifyPiLine('{"type":"agent_end"}');
    expect(classified.kind).toBe("event");
    if (classified.kind === "event") {
      expect((classified.event as { type: string }).type).toBe("agent_end");
    }
  });
});

describe("createRequestIdSource", () => {
  it("allocates monotonic req-N ids, independently per source", () => {
    const next = createRequestIdSource();
    expect([next(), next(), next()]).toEqual(["req-0", "req-1", "req-2"]);
    const other = createRequestIdSource();
    expect(other()).toBe("req-0");
  });
});

describe("shared timeout constants", () => {
  it("keeps the legacy values both consumers were built around", () => {
    expect(DEFAULT_REQUEST_TIMEOUT_MS).toBe(20_000);
    expect(COMPACT_TIMEOUT_MS).toBe(120_000);
  });
});
