import { describe, expect, it } from "vitest";
import { THINKING_LEVELS, thinkingLevelsForModel } from "../src/thinking.ts";

describe("thinkingLevelsForModel", () => {
  it("offers the full ladder for a reasoning-capable model", () => {
    expect(thinkingLevelsForModel(true)).toEqual([...THINKING_LEVELS]);
  });

  it("restricts a non-reasoning model to 'off' only (native supportsThinking fallback)", () => {
    expect(thinkingLevelsForModel(false)).toEqual(["off"]);
  });

  it("defaults to the full ladder when reasoning is unknown (no flash to 'off' while loading)", () => {
    expect(thinkingLevelsForModel(undefined)).toEqual([...THINKING_LEVELS]);
  });
});
