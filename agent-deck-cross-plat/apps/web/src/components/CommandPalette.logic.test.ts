import { describe, expect, it } from "vitest";
import {
  buildPaletteGroups,
  filterPaletteItems,
  flattenPaletteGroups,
  RECENT_SESSION_LIMIT,
  scorePaletteItem,
  type PaletteItem,
} from "./CommandPalette.logic.ts";

function item(overrides: Partial<PaletteItem> & Pick<PaletteItem, "id">): PaletteItem {
  return {
    title: overrides.id,
    keywords: [],
    group: "actions",
    ...overrides,
  };
}

describe("scorePaletteItem", () => {
  it("ranks exact > prefix > substring, and title above keyword hits", () => {
    const exact = scorePaletteItem(item({ id: "a", title: "Git" }), "git");
    const prefix = scorePaletteItem(item({ id: "b", title: "Github issues" }), "git");
    const substring = scorePaletteItem(item({ id: "c", title: "Open Git panel" }), "git");
    expect(exact).toBeGreaterThan(prefix);
    expect(prefix).toBeGreaterThan(substring);

    const titleHit = scorePaletteItem(item({ id: "d", title: "Git", keywords: ["vcs"] }), "git");
    const keywordHit = scorePaletteItem(
      item({ id: "e", title: "Source control", keywords: ["git"] }),
      "git",
    );
    expect(titleHit).toBeGreaterThan(keywordHit);
  });

  it("returns -Infinity when nothing matches", () => {
    expect(scorePaletteItem(item({ id: "x", title: "Terminal" }), "zzz")).toBe(
      Number.NEGATIVE_INFINITY,
    );
  });
});

describe("filterPaletteItems", () => {
  it("returns every item unchanged for an empty query", () => {
    const items = [item({ id: "a" }), item({ id: "b" })];
    expect(filterPaletteItems(items, "")).toEqual(items);
  });

  it("keeps only matches, ordered by score then original position", () => {
    const items = [
      item({ id: "sub", title: "Open the Git diff" }), // substring
      item({ id: "exact", title: "Git" }), // exact
      item({ id: "none", title: "Terminal" }), // no match
      item({ id: "prefix", title: "Git history" }), // prefix
    ];
    expect(filterPaletteItems(items, "git").map((i) => i.id)).toEqual(["exact", "prefix", "sub"]);
  });

  it("matches on keywords when the title does not contain the query", () => {
    const items = [item({ id: "stop", title: "Halt", keywords: ["abort", "cancel"] })];
    expect(filterPaletteItems(items, "abort").map((i) => i.id)).toEqual(["stop"]);
  });
});

describe("buildPaletteGroups", () => {
  it("orders groups and caps the sessions group at the recent limit for an empty query", () => {
    const sessions = Array.from({ length: RECENT_SESSION_LIMIT + 3 }, (_unused, index) =>
      item({ id: `s${index}`, title: `Session ${index}`, group: "sessions" }),
    );
    const groups = buildPaletteGroups({
      items: [
        item({ id: "nav", title: "Go to Git", group: "navigation" }),
        item({ id: "act", title: "New Session", group: "actions" }),
        ...sessions,
      ],
      query: "",
    });

    expect(groups.map((g) => g.id)).toEqual(["actions", "navigation", "sessions"]);
    // Recent-first cap: the first N sessions survive, in source order.
    expect(groups[2]?.items).toHaveLength(RECENT_SESSION_LIMIT);
    expect(groups[2]?.items[0]?.id).toBe("s0");
  });

  it("drops empty groups and ignores the session cap while filtering", () => {
    const sessions = Array.from({ length: RECENT_SESSION_LIMIT + 2 }, (_unused, index) =>
      item({ id: `plan${index}`, title: `Plan work ${index}`, group: "sessions" }),
    );
    const groups = buildPaletteGroups({
      items: [item({ id: "nav", title: "Go to Git", group: "navigation" }), ...sessions],
      query: "plan",
    });

    // The navigation item ("Go to Git") does not match "plan", so its group drops.
    expect(groups.map((g) => g.id)).toEqual(["sessions"]);
    expect(groups[0]?.items).toHaveLength(RECENT_SESSION_LIMIT + 2);
  });

  it("flattens groups into arrow-nav order", () => {
    const groups = buildPaletteGroups({
      items: [
        item({ id: "n1", title: "Go to Git", group: "navigation" }),
        item({ id: "a1", title: "New Session", group: "actions" }),
      ],
      query: "",
    });
    expect(flattenPaletteGroups(groups).map((i) => i.id)).toEqual(["a1", "n1"]);
  });
});
