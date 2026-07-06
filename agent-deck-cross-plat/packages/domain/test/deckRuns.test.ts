import { describe, expect, it } from "vitest";
import {
  deckRuns,
  emptyTranscript,
  reduceTranscript,
  type TranscriptState,
} from "../src/transcript.ts";

function run(events: Parameters<typeof reduceTranscript>[1][]): TranscriptState {
  return events.reduce(reduceTranscript, emptyTranscript());
}

describe("deckRuns: aggregate subagent runs for the deck", () => {
  it("is empty with no subagent cells", () => {
    const state = run([{ type: "cell_final", cell: { kind: "user", id: "u1", text: "hi" } }]);
    expect(deckRuns(state)).toEqual([]);
  });

  it("reports each run's task, status, and progress count in transcript order", () => {
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
      { type: "subagent_progress", cellId: "s1", message: "step 1" },
      { type: "subagent_progress", cellId: "s1", message: "step 2" },
      {
        type: "cell_final",
        cell: {
          kind: "subagent",
          id: "s2",
          task: "Beta",
          status: "done",
          text: "ok",
          progress: [],
        },
      },
    ]);
    expect(deckRuns(state)).toEqual([
      { id: "s1", task: "Alpha", status: "running", progressCount: 2, needsInput: false },
      { id: "s2", task: "Beta", status: "done", progressCount: 0, needsInput: false },
    ]);
  });

  it("flags needsInput while a blocking supervisor request for the run is open, and clears it once answered/closed", () => {
    const base: Parameters<typeof reduceTranscript>[1][] = [
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
    ];
    expect(deckRuns(run(base))[0]!.needsInput).toBe(true);

    // Answered → no longer needs input.
    expect(
      deckRuns(
        run([...base, { type: "supervisor_answered", cellId: "supervisor-r1", answer: "go" }]),
      )[0]!.needsInput,
    ).toBe(false);

    // Closed (timed out / subagent ended) → also no longer needs input.
    expect(
      deckRuns(
        run([...base, { type: "supervisor_closed", cellId: "supervisor-r1", reason: "ended" }]),
      )[0]!.needsInput,
    ).toBe(false);
  });
});
