import { describe, expect, it } from "vitest";
import { Either, Schema } from "effect";
import { ClientMessage } from "../src/index.ts";

/**
 * Golden-fixture validation corpus for `ClientMessage`, the contracts Effect
 * Schema that is the SOLE runtime validator at the `/rpc` socket boundary. Every
 * fixture must accept/reject exactly as recorded.
 *
 * This corpus began (Slice 1) as a zod⇄Effect PARITY test proving the Effect
 * port matched the legacy `@agent-deck/domain` zod validator; that zod validator
 * was retired with the `/ws` envelope in Slice 7c, so the corpus now pins the
 * contracts schema directly. The accept/reject verdicts (including the boundary
 * cases named "…parity…") are the original zod semantics, preserved on purpose.
 */

interface Fixture {
  name: string;
  message: unknown;
  expected: "accept" | "reject";
}

const image = (overrides: Record<string, unknown> = {}) => ({
  type: "image",
  data: "aGVsbG8=",
  mimeType: "image/png",
  ...overrides,
});

const fixtures: Fixture[] = [
  // --- valid: every message type -------------------------------------------
  { name: "hello", message: { type: "hello" }, expected: "accept" },
  {
    name: "hello with unknown extra key (both validators ignore excess keys)",
    message: { type: "hello", extra: "ignored" },
    expected: "accept",
  },
  {
    name: "subscribe_session without lastSeq (fresh snapshot)",
    message: { type: "subscribe_session", sessionId: "s1" },
    expected: "accept",
  },
  {
    name: "subscribe_session with lastSeq 0 (nonnegative boundary)",
    message: { type: "subscribe_session", sessionId: "s1", lastSeq: 0 },
    expected: "accept",
  },
  {
    name: "subscribe_session with lastSeq 42",
    message: { type: "subscribe_session", sessionId: "s1", lastSeq: 42 },
    expected: "accept",
  },
  {
    name: "subscribe_session with explicit undefined lastSeq",
    message: { type: "subscribe_session", sessionId: "s1", lastSeq: undefined },
    expected: "accept",
  },
  {
    name: "subscribe_session with lastSeq MAX_SAFE_INTEGER (2^53 - 1)",
    message: { type: "subscribe_session", sessionId: "s1", lastSeq: Number.MAX_SAFE_INTEGER },
    expected: "accept",
  },
  {
    name: "subscribe_session with unsafe-integer lastSeq 2^53 (zod .int() parity: Number.isInteger, not isSafeInteger)",
    message: { type: "subscribe_session", sessionId: "s1", lastSeq: 2 ** 53 },
    expected: "accept",
  },
  {
    name: "subscribe_session with unsafe-integer lastSeq 2^53 + 2",
    message: { type: "subscribe_session", sessionId: "s1", lastSeq: 2 ** 53 + 2 },
    expected: "accept",
  },
  {
    name: "subscribe_session with huge integer-valued lastSeq 1e21",
    message: { type: "subscribe_session", sessionId: "s1", lastSeq: 1e21 },
    expected: "accept",
  },
  {
    name: "prompt without images",
    message: { type: "prompt", sessionId: "s1", message: "hi" },
    expected: "accept",
  },
  {
    name: "prompt with empty images array",
    message: { type: "prompt", sessionId: "s1", message: "hi", images: [] },
    expected: "accept",
  },
  {
    name: "prompt with 8 images (max boundary)",
    message: {
      type: "prompt",
      sessionId: "s1",
      message: "hi",
      images: Array.from({ length: 8 }, () => image()),
    },
    expected: "accept",
  },
  {
    name: "prompt image data exactly 20_000_000 chars (max boundary)",
    message: {
      type: "prompt",
      sessionId: "s1",
      message: "hi",
      images: [image({ data: "a".repeat(20_000_000) })],
    },
    expected: "accept",
  },
  {
    name: "prompt image mimeType exactly 100 chars (max boundary)",
    message: {
      type: "prompt",
      sessionId: "s1",
      message: "hi",
      images: [image({ mimeType: "m".repeat(100) })],
    },
    expected: "accept",
  },
  {
    name: "steer",
    message: { type: "steer", sessionId: "s1", message: "go left" },
    expected: "accept",
  },
  {
    name: "follow_up",
    message: { type: "follow_up", sessionId: "s1", message: "and then?" },
    expected: "accept",
  },
  { name: "abort", message: { type: "abort", sessionId: "s1" }, expected: "accept" },
  { name: "compact", message: { type: "compact", sessionId: "s1" }, expected: "accept" },
  {
    name: "set_model with 1-char provider/modelId (min boundary)",
    message: { type: "set_model", sessionId: "s1", provider: "p", modelId: "m" },
    expected: "accept",
  },
  {
    name: "set_model with 200-char provider and modelId (max boundary)",
    message: {
      type: "set_model",
      sessionId: "s1",
      provider: "p".repeat(200),
      modelId: "m".repeat(200),
    },
    expected: "accept",
  },
  {
    name: "set_thinking level off",
    message: { type: "set_thinking", sessionId: "s1", level: "off" },
    expected: "accept",
  },
  {
    name: "set_thinking level xhigh",
    message: { type: "set_thinking", sessionId: "s1", level: "xhigh" },
    expected: "accept",
  },
  {
    name: "ui_response with empty payload record",
    message: { type: "ui_response", sessionId: "s1", response: {} },
    expected: "accept",
  },
  {
    name: "ui_response with nested pass-through payload",
    message: {
      type: "ui_response",
      sessionId: "s1",
      response: { id: "u1", value: { nested: [1, "two", null] }, ok: true },
    },
    expected: "accept",
  },

  // --- invalid: tag / envelope problems ------------------------------------
  { name: "unknown discriminator tag", message: { type: "nonsense" }, expected: "reject" },
  { name: "missing type field", message: { sessionId: "s1" }, expected: "reject" },
  { name: "non-string type field", message: { type: 42 }, expected: "reject" },
  { name: "null message", message: null, expected: "reject" },
  { name: "string message", message: "hello", expected: "reject" },
  { name: "array message", message: [{ type: "hello" }], expected: "reject" },

  // --- invalid: per-field constraint probes ---------------------------------
  {
    name: "subscribe_session missing sessionId",
    message: { type: "subscribe_session" },
    expected: "reject",
  },
  {
    name: "subscribe_session with negative lastSeq",
    message: { type: "subscribe_session", sessionId: "s1", lastSeq: -1 },
    expected: "reject",
  },
  {
    name: "subscribe_session with non-integer lastSeq",
    message: { type: "subscribe_session", sessionId: "s1", lastSeq: 1.5 },
    expected: "reject",
  },
  {
    name: "subscribe_session with string lastSeq",
    message: { type: "subscribe_session", sessionId: "s1", lastSeq: "5" },
    expected: "reject",
  },
  {
    name: "subscribe_session with Infinity lastSeq (integer-valued but not an integer)",
    message: { type: "subscribe_session", sessionId: "s1", lastSeq: Number.POSITIVE_INFINITY },
    expected: "reject",
  },
  {
    name: "subscribe_session with NaN lastSeq",
    message: { type: "subscribe_session", sessionId: "s1", lastSeq: Number.NaN },
    expected: "reject",
  },
  {
    name: "prompt missing message",
    message: { type: "prompt", sessionId: "s1" },
    expected: "reject",
  },
  {
    name: "prompt with 9 images (over max)",
    message: {
      type: "prompt",
      sessionId: "s1",
      message: "hi",
      images: Array.from({ length: 9 }, () => image()),
    },
    expected: "reject",
  },
  {
    name: "prompt with non-array images",
    message: { type: "prompt", sessionId: "s1", message: "hi", images: {} },
    expected: "reject",
  },
  {
    name: "prompt image data over 20_000_000 chars",
    message: {
      type: "prompt",
      sessionId: "s1",
      message: "hi",
      images: [image({ data: "a".repeat(20_000_001) })],
    },
    expected: "reject",
  },
  {
    name: "prompt image mimeType over 100 chars",
    message: {
      type: "prompt",
      sessionId: "s1",
      message: "hi",
      images: [image({ mimeType: "m".repeat(101) })],
    },
    expected: "reject",
  },
  {
    name: "prompt image with wrong inner literal tag",
    message: { type: "prompt", sessionId: "s1", message: "hi", images: [image({ type: "file" })] },
    expected: "reject",
  },
  {
    name: "prompt image missing mimeType",
    message: {
      type: "prompt",
      sessionId: "s1",
      message: "hi",
      images: [{ type: "image", data: "x" }],
    },
    expected: "reject",
  },
  {
    name: "steer with non-string message payload",
    message: { type: "steer", sessionId: "s1", message: 7 },
    expected: "reject",
  },
  {
    name: "follow_up missing message",
    message: { type: "follow_up", sessionId: "s1" },
    expected: "reject",
  },
  { name: "abort missing sessionId", message: { type: "abort" }, expected: "reject" },
  {
    name: "set_model with empty provider (under min length 1)",
    message: { type: "set_model", sessionId: "s1", provider: "", modelId: "m" },
    expected: "reject",
  },
  {
    name: "set_model with 201-char modelId (over max)",
    message: { type: "set_model", sessionId: "s1", provider: "p", modelId: "m".repeat(201) },
    expected: "reject",
  },
  {
    name: "set_thinking with unknown level",
    message: { type: "set_thinking", sessionId: "s1", level: "ultra" },
    expected: "reject",
  },
  {
    name: "set_thinking with non-string level",
    message: { type: "set_thinking", sessionId: "s1", level: 3 },
    expected: "reject",
  },
  {
    name: "ui_response with array payload (records reject arrays)",
    message: { type: "ui_response", sessionId: "s1", response: [] },
    expected: "reject",
  },
  {
    name: "ui_response with string payload",
    message: { type: "ui_response", sessionId: "s1", response: "yes" },
    expected: "reject",
  },
  {
    name: "ui_response with null payload",
    message: { type: "ui_response", sessionId: "s1", response: null },
    expected: "reject",
  },
  {
    // The Slice-1 "Effect Record accepts exotics" nuance, now closed: the
    // PlainJsonRecord refinement rejects a Date exactly as zod's record does.
    name: "ui_response with Date payload (exotic object — both reject)",
    message: { type: "ui_response", sessionId: "s1", response: new Date() },
    expected: "reject",
  },
  {
    name: "ui_response with Map payload (exotic object — both reject)",
    message: { type: "ui_response", sessionId: "s1", response: new Map() },
    expected: "reject",
  },
];

const decodeEffect = Schema.decodeUnknownEither(ClientMessage);

describe("ClientMessage Effect Schema validation", () => {
  it("covers at least 25 fixtures with both accept and reject cases", () => {
    expect(fixtures.length).toBeGreaterThanOrEqual(25);
    expect(fixtures.some((f) => f.expected === "accept")).toBe(true);
    expect(fixtures.some((f) => f.expected === "reject")).toBe(true);
  });

  it.each(fixtures)("$name", ({ message, expected }) => {
    const effectAccepts = Either.isRight(decodeEffect(message));
    expect(effectAccepts, "effect verdict").toBe(expected === "accept");
  });
});
