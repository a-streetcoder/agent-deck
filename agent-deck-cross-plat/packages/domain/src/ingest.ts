import type { RpcEventListener, RpcExtensionUIRequest } from "@earendil-works/pi-coding-agent";
import type {
  AssistantBlock,
  AssistantCell,
  BlockKind,
  DomainEvent,
  ToolCell,
  TranscriptCell,
} from "./transcript.ts";

/** pi's streaming event union, derived from the exported listener type. */
export type PiAgentEvent = Parameters<RpcEventListener>[0];
export type PiInboundEvent = PiAgentEvent | RpcExtensionUIRequest;

type AssistantMessage = Extract<
  Extract<PiAgentEvent, { type: "message_end" }>["message"],
  { role: "assistant" }
>;

/**
 * Normalization pipeline: raw pi events in, ordered domain events out.
 *
 * Non-negotiable: `text_delta`/`thinking_delta` pass through as `cell_delta`
 * events — never coalesced away, never deferred to message_end.
 *
 * Entry-id strategy (confirmed pi gotcha — responseId may be absent or reused):
 * the cell id is coined once per message window (message_start → message_end)
 * from a monotonic counter, with the responseId recorded on the cell for
 * cross-referencing. Coined ids are deterministic given the event sequence.
 */
export interface IngestState {
  counter: number;
  openAssistant?: {
    cellId: string;
    blocks: Map<number, { kind: BlockKind; text: string }>;
  };
  /** toolCallIds with a live tool_execution_start cell (merge, don't recreate). */
  seenToolCalls: Set<string>;
}

export function createIngestState(): IngestState {
  return { counter: 0, seenToolCalls: new Set() };
}

function coinId(state: IngestState, prefix: string): string {
  state.counter += 1;
  return `${prefix}-${state.counter}`;
}

function assistantCellFromMessage(id: string, message: AssistantMessage): AssistantCell {
  const blocks = message.content.flatMap((content, contentIndex): AssistantBlock[] => {
    if (content.type === "text") {
      return [{ kind: "text", contentIndex, text: content.text, done: true }];
    }
    if (content.type === "thinking") {
      return [{ kind: "thinking", contentIndex, text: content.thinking, done: true }];
    }
    return [];
  });
  return {
    kind: "assistant",
    id,
    blocks,
    streaming: false,
    model: message.model,
    stopReason: message.stopReason,
    errorMessage: message.errorMessage,
  };
}

function userText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .filter(
        (block): block is { type: "text"; text: string } =>
          typeof block === "object" &&
          block !== null &&
          (block as { type?: string }).type === "text",
      )
      .map((block) => block.text)
      .join("\n");
  }
  return "";
}

/** Feed one pi event; mutates `state`, returns the domain events it produced. */
export function ingestPiEvent(state: IngestState, event: PiInboundEvent): DomainEvent[] {
  switch (event.type) {
    case "agent_start":
      return [{ type: "agent_status", status: "running" }];
    case "agent_end":
      state.openAssistant = undefined;
      return [{ type: "agent_status", status: "idle" }];

    case "message_start": {
      if (event.message.role !== "assistant") return [];
      const cellId = coinId(state, "assistant");
      state.openAssistant = { cellId, blocks: new Map() };
      const cell: TranscriptCell = {
        kind: "assistant",
        id: cellId,
        blocks: [],
        streaming: true,
      };
      return [{ type: "cell_open", cell }];
    }

    case "message_update": {
      const open = state.openAssistant;
      if (!open) return [];
      const ame = event.assistantMessageEvent;
      switch (ame.type) {
        case "text_start":
        case "thinking_start": {
          const kind: BlockKind = ame.type === "text_start" ? "text" : "thinking";
          open.blocks.set(ame.contentIndex, { kind, text: "" });
          return [];
        }
        case "text_delta":
        case "thinking_delta": {
          const kind: BlockKind = ame.type === "text_delta" ? "text" : "thinking";
          const block = open.blocks.get(ame.contentIndex) ?? { kind, text: "" };
          block.text += ame.delta;
          open.blocks.set(ame.contentIndex, block);
          return [
            {
              type: "cell_delta",
              cellId: open.cellId,
              contentIndex: ame.contentIndex,
              blockKind: kind,
              delta: ame.delta,
            },
          ];
        }
        case "text_end":
        case "thinking_end":
          return [
            {
              type: "block_end",
              cellId: open.cellId,
              contentIndex: ame.contentIndex,
              content: ame.content,
            },
          ];
        default:
          // toolcall_* deltas are rendered via tool_execution_* cells; start/done/error
          // are subsumed by message_start/message_end.
          return [];
      }
    }

    case "message_end": {
      const message = event.message;
      if (message.role === "assistant") {
        const cellId = state.openAssistant?.cellId ?? coinId(state, "assistant");
        state.openAssistant = undefined;
        return [{ type: "cell_final", cell: assistantCellFromMessage(cellId, message) }];
      }
      if (message.role === "user") {
        return [
          {
            type: "cell_final",
            cell: { kind: "user", id: coinId(state, "user"), text: userText(message.content) },
          },
        ];
      }
      if (message.role === "toolResult") {
        // Live sessions already have a cell from tool_execution_start — merge.
        // When rebuilding from get_messages (resume) the cell doesn't exist yet.
        if (state.seenToolCalls.has(message.toolCallId)) {
          return [
            {
              type: "tool_end",
              cellId: `tool-${message.toolCallId}`,
              status: message.isError ? "error" : "done",
              result: userText(message.content),
            },
          ];
        }
        return [
          {
            type: "cell_final",
            cell: {
              kind: "tool",
              id: `tool-${message.toolCallId}`,
              toolCallId: message.toolCallId,
              toolName: message.toolName,
              args: undefined,
              status: message.isError ? "error" : "done",
              result: userText(message.content),
            },
          },
        ];
      }
      return [];
    }

    case "tool_execution_start": {
      state.seenToolCalls.add(event.toolCallId);
      const cell: ToolCell = {
        kind: "tool",
        id: `tool-${event.toolCallId}`,
        toolCallId: event.toolCallId,
        toolName: event.toolName,
        args: event.args,
        status: "running",
      };
      return [{ type: "cell_open", cell }];
    }
    case "tool_execution_update":
      return [
        {
          type: "tool_update",
          cellId: `tool-${event.toolCallId}`,
          partialResult: event.partialResult,
        },
      ];
    case "tool_execution_end":
      return [
        {
          type: "tool_end",
          cellId: `tool-${event.toolCallId}`,
          status: event.isError ? "error" : "done",
          result: event.result,
        },
      ];

    case "extension_ui_request": {
      // Only requests that await an answer become cards; fire-and-forget
      // methods (notify, widgets, …) are not questions.
      if (!["select", "confirm", "input", "editor"].includes(event.method)) return [];
      // The union has many variants; extract the display fields structurally.
      const request = event as {
        id: string;
        method: string;
        title?: string;
        message?: string;
        options?: string[];
        placeholder?: string;
      };
      const cell: TranscriptCell = {
        kind: "question",
        id: `question-${request.id}`,
        requestId: request.id,
        method: request.method,
        title: request.title ?? request.method,
        message: request.message,
        options: request.options,
        placeholder: request.placeholder,
        answered: false,
      };
      return [{ type: "cell_open", cell }];
    }

    default:
      // turn_start/turn_end, queue/compaction/retry events: handled in later
      // slices; cell_final self-healing keeps the transcript sound.
      return [];
  }
}
