import { describe, expect, it } from "vitest";
import { conflictingExtensionNames } from "../src/extensions.ts";

/**
 * Extensions conflict flagging (native §16.2): two ENABLED extensions with the
 * same filename collide; disabling one resolves it.
 */

describe("conflictingExtensionNames", () => {
  it("flags a name used by two enabled extensions", () => {
    const conflicts = conflictingExtensionNames([
      { name: "memory.ts", disabled: false },
      { name: "memory.ts", disabled: false },
      { name: "other.ts", disabled: false },
    ]);
    expect([...conflicts]).toEqual(["memory.ts"]);
  });

  it("does not flag when one of the duplicates is disabled", () => {
    const conflicts = conflictingExtensionNames([
      { name: "memory.ts", disabled: false },
      { name: "memory.ts", disabled: true },
    ]);
    expect(conflicts.size).toBe(0);
  });

  it("flags only names with 2+ enabled copies (3 copies still one entry)", () => {
    const conflicts = conflictingExtensionNames([
      { name: "dup.ts", disabled: false },
      { name: "dup.ts", disabled: false },
      { name: "dup.ts", disabled: false },
      { name: "solo.ts", disabled: false },
    ]);
    expect([...conflicts]).toEqual(["dup.ts"]);
  });

  it("returns an empty set for all-distinct or empty input", () => {
    expect(conflictingExtensionNames([]).size).toBe(0);
    expect(
      conflictingExtensionNames([
        { name: "a.ts", disabled: false },
        { name: "b.ts", disabled: false },
      ]).size,
    ).toBe(0);
  });
});
