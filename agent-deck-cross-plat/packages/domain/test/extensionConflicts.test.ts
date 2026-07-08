import { describe, expect, it } from "vitest";
import { conflictingExtensionNames, extensionBridgeConflict } from "../src/extensions.ts";

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

describe("extensionBridgeConflict", () => {
  it("flags an extension registering an app-bridge tool name", () => {
    expect(
      extensionBridgeConflict(`pi.registerTool({ name: "agent_deck_memory_write" }, fn)`),
    ).toBe("agent_deck_memory_write");
    expect(extensionBridgeConflict(`pi.registerTool({ name: 'managed_subagent' }, fn)`)).toBe(
      "managed_subagent",
    );
  });

  it("flags an mcp__ proxy tool literal", () => {
    expect(extensionBridgeConflict('const t = "mcp__github__create_issue";')).toBe(
      "mcp__github__create_issue",
    );
  });

  it("returns null for an extension that touches no bridge tool", () => {
    expect(extensionBridgeConflict(`pi.on("before_agent_start", () => ({}))`)).toBeNull();
    // A substring that isn't a quoted literal doesn't false-positive.
    expect(extensionBridgeConflict(`// mentions managed_subagent in a comment`)).toBeNull();
  });
});
