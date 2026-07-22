import { describe, expect, it } from "vitest";
import {
  emptyTranscript,
  openQuestion,
  reduceTranscript,
  type TranscriptState,
} from "../src/transcript.ts";

function run(events: Parameters<typeof reduceTranscript>[1][]): TranscriptState {
  return events.reduce(reduceTranscript, emptyTranscript());
}

const questionCell = (id: string) => ({
  type: "cell_open" as const,
  cell: {
    kind: "question" as const,
    id: `question-${id}`,
    requestId: id,
    method: "input",
    title: `Q ${id}`,
    answered: false,
  },
});

describe("openQuestion: the single live extension_ui_request", () => {
  it("is null with no question cells", () => {
    const state = run([{ type: "cell_final", cell: { kind: "user", id: "u1", text: "hi" } }]);
    expect(openQuestion(state)).toBeNull();
  });

  it("returns the open question cell", () => {
    const state = run([questionCell("r1")]);
    expect(openQuestion(state)?.requestId).toBe("r1");
  });

  it("returns null once the question is answered", () => {
    const state = run([questionCell("r1"), { type: "question_answered", cellId: "question-r1" }]);
    expect(openQuestion(state)).toBeNull();
  });

  it("returns the first unanswered question in transcript order", () => {
    const state = run([
      questionCell("r1"),
      { type: "question_answered", cellId: "question-r1" },
      questionCell("r2"),
    ]);
    expect(openQuestion(state)?.requestId).toBe("r2");
  });
});
