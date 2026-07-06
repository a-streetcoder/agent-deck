import { describe, expect, it } from "vitest";
import { emptyTranscript, reduceTranscript, type TranscriptState } from "../src/transcript.ts";

function run(events: Parameters<typeof reduceTranscript>[1][]): TranscriptState {
  return events.reduce(reduceTranscript, emptyTranscript());
}

describe("session plan reducer", () => {
  it("starts empty", () => {
    expect(emptyTranscript().plan).toEqual([]);
  });

  it("plan_set replaces the whole plan", () => {
    const state = run([
      {
        type: "plan_set",
        items: [
          { id: "a", title: "A", status: "todo" },
          { id: "b", title: "B", status: "in_progress" },
        ],
      },
      { type: "plan_set", items: [{ id: "c", title: "C", status: "done" }] },
    ]);
    expect(state.plan).toEqual([{ id: "c", title: "C", status: "done" }]);
  });

  it("plan_update patches items by id (status and/or title), ignoring unknown ids", () => {
    const state = run([
      {
        type: "plan_set",
        items: [
          { id: "a", title: "A", status: "todo" },
          { id: "b", title: "B", status: "todo" },
        ],
      },
      {
        type: "plan_update",
        updates: [
          { id: "a", status: "done" },
          { id: "b", title: "B renamed" },
          { id: "ghost", status: "blocked" },
        ],
      },
    ]);
    expect(state.plan).toEqual([
      { id: "a", title: "A", status: "done" },
      { id: "b", title: "B renamed", status: "todo" },
    ]);
  });
});
