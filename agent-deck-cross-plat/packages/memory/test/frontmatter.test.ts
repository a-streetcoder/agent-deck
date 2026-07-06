import { describe, expect, it } from "vitest";
import { parseMemory, serializeMemory } from "../src/frontmatter.ts";
import type { MemoryRecord } from "../src/types.ts";

const record: MemoryRecord = {
  id: "mem_20260706_context_x_abcdef",
  type: "context",
  scope: "project",
  status: "active",
  title: "A title: with a colon",
  summary: "A summary — with punctuation & an ampersand",
  body: "Body line one.\n\nBody line two with a fake --- divider inside.",
  createdAt: "2026-07-06T00:00:00.000Z",
  updatedAt: "2026-07-06T00:00:00.000Z",
  tags: ["a", "b"],
};

describe("memory frontmatter", () => {
  it("round-trips fields, including YAML-special title/summary and a body divider", () => {
    const parsed = parseMemory(serializeMemory(record));
    expect(parsed).toMatchObject({
      id: record.id,
      title: record.title,
      summary: record.summary,
      tags: record.tags,
      type: "context",
      status: "active",
    });
    // The "---" inside the body must not truncate re-parsing.
    expect(parsed!.body).toContain("fake --- divider");
    expect(parsed!.body).toContain("Body line two");
  });

  it("parses a CRLF-authored file (hand-edited on Windows)", () => {
    const crlf = serializeMemory(record).replace(/\n/g, "\r\n");
    const parsed = parseMemory(crlf);
    expect(parsed).not.toBeNull();
    expect(parsed!.title).toBe(record.title);
    expect(parsed!.body).toContain("Body line one.");
  });

  it("returns null for a file with no frontmatter", () => {
    expect(parseMemory("# just markdown, no frontmatter")).toBeNull();
  });
});
