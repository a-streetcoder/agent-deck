import { describe, expect, it } from "vitest";
import {
  appendElementContextsToPrompt,
  buildElementContextBlock,
  buildPendingElementContext,
  deriveTagName,
  formatElementContextLabel,
  type PendingElementContext,
} from "./elementContext.ts";

function context(overrides: Partial<PendingElementContext> = {}): PendingElementContext {
  return {
    id: "el_1",
    pageUrl: "http://localhost:3000/",
    selector: "button.primary",
    tagName: "button",
    note: "Make this larger",
    ...overrides,
  };
}

describe("deriveTagName", () => {
  it("reads the type selector of a simple compound", () => {
    expect(deriveTagName("button")).toBe("button");
    expect(deriveTagName("button.primary")).toBe("button");
    expect(deriveTagName("input[type=text]")).toBe("input");
    expect(deriveTagName("DIV#main")).toBe("div");
  });

  it("takes the LAST compound of a descendant/child/sibling selector", () => {
    expect(deriveTagName("div > button.primary")).toBe("button");
    expect(deriveTagName("nav ul li a")).toBe("a");
    expect(deriveTagName("h1 + p")).toBe("p");
    expect(deriveTagName("section ~ span.note")).toBe("span");
  });

  it("falls back to 'element' for class/id/attribute-only or missing selectors", () => {
    expect(deriveTagName(".cta")).toBe("element");
    expect(deriveTagName("#save")).toBe("element");
    expect(deriveTagName("[data-role=dialog]")).toBe("element");
    expect(deriveTagName("")).toBe("element");
    expect(deriveTagName("   ")).toBe("element");
    expect(deriveTagName(null)).toBe("element");
  });
});

describe("formatElementContextLabel", () => {
  it("wraps the tag in angle brackets", () => {
    expect(formatElementContextLabel({ tagName: "button" })).toBe("<button>");
    expect(formatElementContextLabel({ tagName: "element" })).toBe("<element>");
  });

  it("truncates an over-long tag", () => {
    const label = formatElementContextLabel({ tagName: "a".repeat(40) });
    expect(label.length).toBeLessThanOrEqual(26); // <…> + 24 cap
    expect(label.endsWith("…>")).toBe(true);
  });
});

describe("buildPendingElementContext", () => {
  it("builds a context from a selector + note, deriving the tag", () => {
    const built = buildPendingElementContext({
      id: "el_9",
      pageUrl: "http://localhost:5173/about",
      selector: "  header nav a.active  ",
      note: "  Highlight the active link  ",
    });
    expect(built).toEqual({
      id: "el_9",
      pageUrl: "http://localhost:5173/about",
      selector: "header nav a.active",
      tagName: "a",
      note: "Highlight the active link",
    });
  });

  it("accepts a note-only capture (no selector)", () => {
    const built = buildPendingElementContext({
      id: "el_2",
      pageUrl: "http://localhost:3000/",
      selector: "  ",
      note: "The submit button at the bottom",
    });
    expect(built?.selector).toBeNull();
    expect(built?.tagName).toBe("element");
    expect(built?.note).toBe("The submit button at the bottom");
  });

  it("accepts a selector-only capture (no note)", () => {
    const built = buildPendingElementContext({
      id: "el_3",
      pageUrl: "http://localhost:3000/",
      selector: "footer",
      note: "   ",
    });
    expect(built?.selector).toBe("footer");
    expect(built?.note).toBe("");
  });

  it("returns null when neither a selector nor a note is given", () => {
    expect(
      buildPendingElementContext({
        id: "el_4",
        pageUrl: "http://localhost:3000/",
        selector: "",
        note: "",
      }),
    ).toBeNull();
  });
});

describe("buildElementContextBlock", () => {
  it("returns '' for an empty set", () => {
    expect(buildElementContextBlock([])).toBe("");
  });

  it("serializes a single context as the donor's <element_context> block", () => {
    expect(buildElementContextBlock([context()])).toBe(
      [
        "<element_context>",
        "- <button>:",
        "  url: http://localhost:3000/",
        "  selector: button.primary",
        "  note: Make this larger",
        "</element_context>",
      ].join("\n"),
    );
  });

  it("omits absent selector/note lines", () => {
    const block = buildElementContextBlock([
      context({ selector: null, tagName: "element", note: "Only a description" }),
    ]);
    expect(block).toContain("- <element>:");
    expect(block).toContain("  note: Only a description");
    expect(block).not.toContain("  selector:");
  });

  it("indents a multi-line note under a note: heading", () => {
    const block = buildElementContextBlock([context({ note: "line one\nline two" })]);
    expect(block).toContain("  note:\n    line one\n    line two");
  });

  it("separates multiple contexts with a blank line", () => {
    const block = buildElementContextBlock([
      context({ id: "a", selector: "button", tagName: "button", note: "first" }),
      context({ id: "b", selector: "a.link", tagName: "a", note: "second" }),
    ]);
    expect(block).toBe(
      [
        "<element_context>",
        "- <button>:",
        "  url: http://localhost:3000/",
        "  selector: button",
        "  note: first",
        "",
        "- <a>:",
        "  url: http://localhost:3000/",
        "  selector: a.link",
        "  note: second",
        "</element_context>",
      ].join("\n"),
    );
  });
});

describe("appendElementContextsToPrompt", () => {
  it("returns the prompt unchanged with no contexts", () => {
    expect(appendElementContextsToPrompt("hello", [])).toBe("hello");
  });

  it("appends the block after the trimmed prompt", () => {
    const out = appendElementContextsToPrompt("  Fix this  ", [context()]);
    expect(out.startsWith("Fix this\n\n<element_context>")).toBe(true);
    expect(out.endsWith("</element_context>")).toBe(true);
  });

  it("emits the block alone when the prompt is empty (contexts-only turn)", () => {
    const out = appendElementContextsToPrompt("   ", [context()]);
    expect(out.startsWith("<element_context>")).toBe(true);
  });
});
