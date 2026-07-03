import { describe, expect, it } from "vitest";
import { createIngestState, ingestPiEvent, type PiInboundEvent } from "../src/ingest.ts";
import { emptyTranscript, reduceTranscript, type TranscriptState } from "../src/transcript.ts";

function assistantMessage(content: unknown[]): unknown {
  return {
    role: "assistant",
    content,
    api: "openai-completions",
    provider: "mock",
    model: "mock-model",
    usage: { input: 1, output: 1 },
    stopReason: "stop",
    timestamp: 0,
  };
}

// Synthetic but shape-faithful pi event sequence for one prompt → reply turn.
const TURN: unknown[] = [
  { type: "agent_start" },
  { type: "turn_start" },
  { type: "message_end", message: { role: "user", content: "hi", timestamp: 0 } },
  { type: "message_start", message: assistantMessage([]) },
  {
    type: "message_update",
    message: assistantMessage([]),
    assistantMessageEvent: { type: "text_start", contentIndex: 0, partial: assistantMessage([]) },
  },
  {
    type: "message_update",
    message: assistantMessage([]),
    assistantMessageEvent: {
      type: "text_delta",
      contentIndex: 0,
      delta: "Hel",
      partial: assistantMessage([]),
    },
  },
  {
    type: "message_update",
    message: assistantMessage([]),
    assistantMessageEvent: {
      type: "text_delta",
      contentIndex: 0,
      delta: "lo!",
      partial: assistantMessage([]),
    },
  },
  {
    type: "message_update",
    message: assistantMessage([]),
    assistantMessageEvent: {
      type: "text_end",
      contentIndex: 0,
      content: "Hello!",
      partial: assistantMessage([]),
    },
  },
  {
    type: "message_end",
    message: assistantMessage([{ type: "text", text: "Hello!" }]),
  },
  { type: "agent_end", messages: [] },
];

function runThrough(events: unknown[]): { state: TranscriptState; deltaCount: number } {
  const ingest = createIngestState();
  let state = emptyTranscript();
  let deltaCount = 0;
  for (const piEvent of events) {
    for (const domainEvent of ingestPiEvent(ingest, piEvent as PiInboundEvent)) {
      if (domainEvent.type === "cell_delta") deltaCount += 1;
      state = reduceTranscript(state, domainEvent);
    }
  }
  return { state, deltaCount };
}

describe("ingest → reduce pipeline", () => {
  it("streams deltas through (never coalesced into message_end)", () => {
    const { deltaCount } = runThrough(TURN);
    expect(deltaCount).toBe(2);
  });

  it("builds the expected transcript for a full turn", () => {
    const { state } = runThrough(TURN);
    expect(state.agentStatus).toBe("idle");
    expect(state.cells).toHaveLength(2);
    expect(state.cells[0]).toMatchObject({ kind: "user", text: "hi" });
    expect(state.cells[1]).toMatchObject({
      kind: "assistant",
      streaming: false,
      blocks: [{ kind: "text", contentIndex: 0, text: "Hello!", done: true }],
    });
  });

  it("shows accumulated partial text mid-stream", () => {
    const { state } = runThrough(TURN.slice(0, 7)); // through the two deltas
    const assistant = state.cells.find((c) => c.kind === "assistant");
    expect(assistant).toMatchObject({
      streaming: true,
      blocks: [{ kind: "text", text: "Hello!", done: false }],
    });
  });

  it("cell_final is authoritative even if a delta was lost (self-healing)", () => {
    const withLostDelta = [...TURN.slice(0, 6), ...TURN.slice(7)]; // drop the second delta
    const { state } = runThrough(withLostDelta);
    const assistant = state.cells.find((c) => c.kind === "assistant");
    expect(assistant).toMatchObject({
      blocks: [{ kind: "text", text: "Hello!", done: true }],
    });
  });

  it("coins distinct assistant cell ids across turns (responseId gotcha)", () => {
    const { state } = runThrough([...TURN, ...TURN]);
    const ids = state.cells.map((c) => c.id);
    expect(new Set(ids).size).toBe(ids.length);
    expect(state.cells).toHaveLength(4);
  });

  it("tracks tool execution lifecycle without losing args on end", () => {
    const events: unknown[] = [
      { type: "tool_execution_start", toolCallId: "t1", toolName: "bash", args: { command: "ls" } },
      {
        type: "tool_execution_update",
        toolCallId: "t1",
        toolName: "bash",
        args: {},
        partialResult: "a",
      },
      {
        type: "tool_execution_end",
        toolCallId: "t1",
        toolName: "bash",
        result: "a\nb",
        isError: false,
      },
    ];
    const { state } = runThrough(events);
    expect(state.cells[0]).toMatchObject({
      kind: "tool",
      toolName: "bash",
      args: { command: "ls" },
      status: "done",
      result: "a\nb",
    });
  });
});
