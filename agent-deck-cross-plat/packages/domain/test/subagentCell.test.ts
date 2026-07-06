import { describe, expect, it } from "vitest";
import {
  emptyTranscript,
  reduceTranscript,
  type SubagentCell,
  type TranscriptState,
} from "../src/transcript.ts";

/** Drive the reducer through a list of events and return the final state. */
function run(events: Parameters<typeof reduceTranscript>[1][]): TranscriptState {
  return events.reduce(reduceTranscript, emptyTranscript());
}

function subagentCells(state: TranscriptState): SubagentCell[] {
  return state.cells.filter((c): c is SubagentCell => c.kind === "subagent");
}

function openCell(id: string, task = "T"): Parameters<typeof reduceTranscript>[1] {
  return {
    type: "cell_open",
    cell: { kind: "subagent", id, task, status: "running", text: "", progress: [] },
  };
}

describe("subagent cell reducer", () => {
  it("opens, accumulates streamed deltas, and finalizes with authoritative text", () => {
    const state = run([
      openCell("s1"),
      { type: "subagent_delta", cellId: "s1", delta: "Hel" },
      { type: "subagent_delta", cellId: "s1", delta: "lo" },
      {
        type: "cell_final",
        cell: {
          kind: "subagent",
          id: "s1",
          task: "T",
          status: "done",
          text: "Hello, world",
          progress: [],
        },
      },
    ]);
    const cells = subagentCells(state);
    expect(cells).toHaveLength(1);
    // cell_final REPLACES the cell, so a lost delta can never corrupt the card.
    expect(cells[0]).toEqual({
      kind: "subagent",
      id: "s1",
      task: "T",
      status: "done",
      text: "Hello, world",
      progress: [],
    });
  });

  it("ignores a delta for an unknown or non-subagent cell (self-healing)", () => {
    const state = run([
      {
        type: "cell_open",
        cell: {
          kind: "tool",
          id: "tool-x",
          toolCallId: "x",
          toolName: "t",
          args: {},
          status: "running",
        },
      },
      // Delta for a never-opened subagent cell: dropped, transcript untouched.
      { type: "subagent_delta", cellId: "s-missing", delta: "ignored" },
      // Delta targeting a tool cell by id: kind mismatch, also dropped.
      { type: "subagent_delta", cellId: "tool-x", delta: "ignored" },
      // Progress for a non-subagent cell: also dropped.
      { type: "subagent_progress", cellId: "tool-x", message: "ignored" },
    ]);
    expect(subagentCells(state)).toHaveLength(0);
    expect(state.cells).toHaveLength(1);
    expect(state.cells[0]!.kind).toBe("tool");
  });

  it("keeps concurrent subagent cells independent (managed_parallel)", () => {
    const state = run([
      openCell("a", "A"),
      openCell("b", "B"),
      { type: "subagent_delta", cellId: "a", delta: "alpha" },
      { type: "subagent_delta", cellId: "b", delta: "beta" },
      { type: "subagent_delta", cellId: "a", delta: "!" },
    ]);
    const byId = Object.fromEntries(subagentCells(state).map((c) => [c.id, c.text]));
    expect(byId).toEqual({ a: "alpha!", b: "beta" });
  });

  it("accumulates progress updates and preserves them across finalization", () => {
    const state = run([
      openCell("s1"),
      { type: "subagent_progress", cellId: "s1", message: "reading files" },
      { type: "subagent_delta", cellId: "s1", delta: "partial" },
      { type: "subagent_progress", cellId: "s1", message: "halfway" },
      // Finalize with authoritative text; progress must survive the replace.
      {
        type: "cell_final",
        cell: {
          kind: "subagent",
          id: "s1",
          task: "T",
          status: "done",
          text: "the answer",
          progress: [],
        },
      },
    ]);
    const cell = subagentCells(state)[0]!;
    expect(cell.text).toBe("the answer");
    expect(cell.progress).toEqual(["reading files", "halfway"]);
  });
});
