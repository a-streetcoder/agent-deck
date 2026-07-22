import { afterEach, describe, expect, it, vi } from "vitest";
import { signalAttention } from "./native.ts";

const stubBridge = (bridge: unknown): void => {
  vi.stubGlobal("window", { agentDeck: bridge });
};

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("signalAttention", () => {
  it("forwards the payload to the Electron bridge when present", () => {
    const signal = vi.fn();
    stubBridge({ isElectron: true, signalAttention: signal });

    signalAttention({ kind: "turn-complete", title: "My session", body: "Turn complete" });

    expect(signal).toHaveBeenCalledTimes(1);
    expect(signal).toHaveBeenCalledWith({
      kind: "turn-complete",
      title: "My session",
      body: "Turn complete",
    });
  });

  it("is a no-op in a plain browser (no bridge)", () => {
    stubBridge(undefined);
    // Must not throw when window.agentDeck is absent.
    expect(() => signalAttention({ kind: "approval-needed", title: "x", body: "y" })).not.toThrow();
  });

  it("is a no-op against an older bridge lacking signalAttention", () => {
    stubBridge({ isElectron: true });
    expect(() => signalAttention({ kind: "turn-complete", title: "x", body: "y" })).not.toThrow();
  });

  it("swallows a throwing bridge so a domain-transition detector never sees it", () => {
    const signal = vi.fn(() => {
      throw new Error("ipc down");
    });
    stubBridge({ isElectron: true, signalAttention: signal });

    expect(() => signalAttention({ kind: "turn-complete", title: "x", body: "y" })).not.toThrow();
    expect(signal).toHaveBeenCalledTimes(1);
  });
});
