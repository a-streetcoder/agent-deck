import { describe, expect, it } from "vitest";
import { parseFileMentions, removeFileMention } from "./fileMentions.ts";

describe("parseFileMentions", () => {
  it("finds a mention at string start", () => {
    expect(parseFileMentions("@src/App.tsx ")).toEqual([
      { path: "src/App.tsx", start: 0, end: 12 },
    ]);
  });

  it("finds a mention after whitespace but not mid-word emails", () => {
    expect(parseFileMentions("hello me@example.com")).toEqual([]);
    const parsed = parseFileMentions("look at @a/b.ts please");
    expect(parsed).toEqual([{ path: "a/b.ts", start: 8, end: 15 }]);
  });

  it("returns one entry per occurrence, in order", () => {
    const parsed = parseFileMentions("@a.ts and @b.ts and @a.ts");
    expect(parsed.map((m) => m.path)).toEqual(["a.ts", "b.ts", "a.ts"]);
    // Each start points at its own `@`.
    for (const m of parsed) expect("@a.ts and @b.ts and @a.ts"[m.start]).toBe("@");
  });

  it("ignores a bare @ with no path", () => {
    expect(parseFileMentions("@ ")).toEqual([]);
    expect(parseFileMentions("text @ more")).toEqual([]);
  });
});

describe("removeFileMention", () => {
  it("removes a leading mention and its trailing space", () => {
    expect(removeFileMention("@src/App.tsx rest", 0)).toBe("rest");
  });

  it("removes a mid-draft mention, collapsing one space", () => {
    expect(removeFileMention("look at @a/b.ts please", 8)).toBe("look at please");
  });

  it("removes a trailing mention without leaving a dangling space", () => {
    expect(removeFileMention("look at @a/b.ts", 8)).toBe("look at");
  });

  it("is a no-op when no mention starts at the index", () => {
    expect(removeFileMention("look at @a/b.ts", 3)).toBe("look at @a/b.ts");
  });

  it("removes only the targeted occurrence when a path repeats", () => {
    const draft = "@a.ts and @a.ts";
    // Remove the second occurrence (start index 10).
    expect(removeFileMention(draft, 10)).toBe("@a.ts and");
    // Remove the first occurrence (start index 0).
    expect(removeFileMention(draft, 0)).toBe("and @a.ts");
  });
});
