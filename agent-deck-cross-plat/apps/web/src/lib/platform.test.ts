import { afterEach, describe, expect, it, vi } from "vitest";
import { detectPlatform } from "./platform.ts";

const stubNavigator = (
  value: Partial<Navigator> & { userAgentData?: { platform?: string } },
): void => {
  vi.stubGlobal("navigator", value as unknown as Navigator);
};

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("detectPlatform", () => {
  it("prefers the modern userAgentData.platform over the deprecated navigator.platform", () => {
    stubNavigator({ userAgentData: { platform: "macOS" }, platform: "Win32" });
    // The keybindings core matches /mac/i, so "macOS" must win here.
    expect(detectPlatform()).toBe("macOS");
  });

  it("falls back to navigator.platform when userAgentData is absent", () => {
    stubNavigator({ platform: "MacIntel" });
    expect(detectPlatform()).toBe("MacIntel");
  });

  it("falls back to navigator.platform when userAgentData has no platform field", () => {
    stubNavigator({ userAgentData: {}, platform: "Linux x86_64" });
    expect(detectPlatform()).toBe("Linux x86_64");
  });

  it("coalesces an empty-but-present userAgentData.platform to the legacy field", () => {
    // "" must not shadow a usable navigator.platform (would flip ⌘→Ctrl on a Mac).
    stubNavigator({ userAgentData: { platform: "" }, platform: "MacIntel" });
    expect(detectPlatform()).toBe("MacIntel");
  });

  it("returns an empty string (→ non-Mac, Ctrl) when nothing is detectable", () => {
    stubNavigator({ platform: undefined as unknown as string });
    expect(detectPlatform()).toBe("");
  });
});
