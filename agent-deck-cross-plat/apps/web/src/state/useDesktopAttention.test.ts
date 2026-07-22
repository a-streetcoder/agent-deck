import { describe, expect, it } from "vitest";
import { attentionEventsFor, type AttentionState } from "./useDesktopAttention.ts";

const s = (status: "idle" | "running", questionId: string | null = null): AttentionState => ({
  status,
  questionId,
});

describe("attentionEventsFor", () => {
  it("raises turn-complete on a running → idle edge", () => {
    expect(attentionEventsFor(s("running"), s("idle"))).toEqual(["turn-complete"]);
  });

  it("does NOT raise turn-complete on idle → idle or running → running", () => {
    expect(attentionEventsFor(s("idle"), s("idle"))).toEqual([]);
    expect(attentionEventsFor(s("running"), s("running"))).toEqual([]);
  });

  it("raises approval-needed on the null → non-null question edge", () => {
    expect(attentionEventsFor(s("idle", null), s("idle", "q1"))).toEqual(["approval-needed"]);
  });

  it("raises approval-needed on a SECOND distinct approval (non-null → different non-null)", () => {
    // The fix: a new pending approval must notify even without an intervening null.
    expect(attentionEventsFor(s("idle", "q1"), s("idle", "q2"))).toEqual(["approval-needed"]);
  });

  it("does NOT re-raise approval-needed when the same question id persists", () => {
    expect(attentionEventsFor(s("running", "q1"), s("idle", "q1"))).toEqual(["turn-complete"]);
  });

  it("does NOT raise approval-needed when a question is answered (non-null → null)", () => {
    expect(attentionEventsFor(s("idle", "q1"), s("idle", null))).toEqual([]);
  });

  it("raises BOTH when a turn completes and an approval appears in one transition", () => {
    expect(attentionEventsFor(s("running", null), s("idle", "q1"))).toEqual([
      "turn-complete",
      "approval-needed",
    ]);
  });

  it("raises nothing from a null baseline (first observation / re-baseline)", () => {
    // The hook passes prev=null on the first tick and after a session switch — no edge.
    expect(attentionEventsFor(null, s("idle", "q1"))).toEqual([]);
    expect(attentionEventsFor(null, s("running"))).toEqual([]);
  });
});
