import { describe, expect, it } from "vitest";
import {
  emptyTranscript,
  reduceTranscript,
  type SupervisorQuestionCell,
  type TranscriptState,
} from "../src/transcript.ts";

function run(events: Parameters<typeof reduceTranscript>[1][]): TranscriptState {
  return events.reduce(reduceTranscript, emptyTranscript());
}

function open(requestId: string): Parameters<typeof reduceTranscript>[1] {
  return {
    type: "cell_open",
    cell: {
      kind: "supervisor_question",
      id: `supervisor-${requestId}`,
      requestId,
      subagentCellId: "subagent-1",
      method: "need_decision",
      title: "Which format?",
      message: "JSON or YAML?",
      options: ["JSON", "YAML"],
      answered: false,
    },
  };
}

describe("supervisor question cell reducer", () => {
  it("opens unanswered and flips to answered with the response", () => {
    const state = run([
      open("r1"),
      { type: "supervisor_answered", cellId: "supervisor-r1", answer: "use JSON" },
    ]);
    const cell = state.cells.find(
      (c): c is SupervisorQuestionCell => c.kind === "supervisor_question",
    )!;
    expect(cell.answered).toBe(true);
    expect(cell.answer).toBe("use JSON");
  });

  it("closes a pending card without an answer (timeout / subagent ended)", () => {
    const state = run([
      open("r1"),
      { type: "supervisor_closed", cellId: "supervisor-r1", reason: "The subagent ended." },
    ]);
    const cell = state.cells.find(
      (c): c is SupervisorQuestionCell => c.kind === "supervisor_question",
    )!;
    expect(cell.answered).toBe(false);
    expect(cell.closed).toBe(true);
    expect(cell.closedReason).toBe("The subagent ended.");
  });

  it("does not close a card that was already answered (answer wins)", () => {
    const state = run([
      open("r1"),
      { type: "supervisor_answered", cellId: "supervisor-r1", answer: "use JSON" },
      { type: "supervisor_closed", cellId: "supervisor-r1", reason: "timed out" },
    ]);
    const cell = state.cells.find(
      (c): c is SupervisorQuestionCell => c.kind === "supervisor_question",
    )!;
    expect(cell.answered).toBe(true);
    expect(cell.answer).toBe("use JSON");
    expect(cell.closed).toBeUndefined();
  });

  it("ignores an answer for an unknown or non-supervisor cell", () => {
    const state = run([
      open("r1"),
      // Wrong id: no matching cell — dropped.
      { type: "supervisor_answered", cellId: "supervisor-missing", answer: "x" },
    ]);
    const cell = state.cells.find(
      (c): c is SupervisorQuestionCell => c.kind === "supervisor_question",
    )!;
    expect(cell.answered).toBe(false);
    expect(cell.answer).toBeUndefined();
  });
});
