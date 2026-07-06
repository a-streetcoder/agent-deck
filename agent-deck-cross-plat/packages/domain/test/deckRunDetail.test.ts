import { describe, expect, it } from "vitest";
import {
  deckRunDetail,
  emptyTranscript,
  reduceTranscript,
  type TranscriptState,
} from "../src/transcript.ts";

function run(events: Parameters<typeof reduceTranscript>[1][]): TranscriptState {
  return events.reduce(reduceTranscript, emptyTranscript());
}

describe("deckRunDetail: the full detail behind one deck run", () => {
  it("returns the subagent cell and its linked supervisor questions", () => {
    const state = run([
      {
        type: "cell_open",
        cell: {
          kind: "subagent",
          id: "s1",
          task: "Alpha",
          status: "running",
          text: "",
          progress: [],
        },
      },
      { type: "subagent_delta", cellId: "s1", delta: "partial output" },
      { type: "subagent_progress", cellId: "s1", message: "step 1" },
      {
        type: "cell_open",
        cell: {
          kind: "supervisor_question",
          id: "supervisor-r1",
          requestId: "r1",
          subagentCellId: "s1",
          method: "need_decision",
          title: "?",
          answered: false,
        },
      },
      // A question for a DIFFERENT run must not leak into s1's detail.
      {
        type: "cell_open",
        cell: {
          kind: "supervisor_question",
          id: "supervisor-r2",
          requestId: "r2",
          subagentCellId: "s2",
          method: "need_decision",
          title: "other",
          answered: false,
        },
      },
    ]);
    const detail = deckRunDetail(state, "s1");
    expect(detail.cell?.text).toBe("partial output");
    expect(detail.cell?.progress).toEqual(["step 1"]);
    expect(detail.questions.map((q) => q.requestId)).toEqual(["r1"]);
  });

  it("returns an undefined cell (and no questions) for an unknown run id", () => {
    const state = run([
      {
        type: "cell_open",
        cell: {
          kind: "subagent",
          id: "s1",
          task: "Alpha",
          status: "running",
          text: "",
          progress: [],
        },
      },
    ]);
    const detail = deckRunDetail(state, "missing");
    expect(detail.cell).toBeUndefined();
    expect(detail.questions).toEqual([]);
  });
});
