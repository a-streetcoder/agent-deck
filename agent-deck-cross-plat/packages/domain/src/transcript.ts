/**
 * Transcript domain model: the cells a chat renders, and the ordered domain
 * events that build them. One reducer implementation is shared by the server
 * (authoritative in-memory state) and the web UI (client mirror).
 */

export type BlockKind = "text" | "thinking";

export interface AssistantBlock {
  kind: BlockKind;
  contentIndex: number;
  text: string;
  done: boolean;
}

export interface UserCell {
  kind: "user";
  id: string;
  text: string;
}

export interface AssistantCell {
  kind: "assistant";
  id: string;
  blocks: AssistantBlock[];
  streaming: boolean;
  model?: string;
  stopReason?: string;
  errorMessage?: string;
}

export interface ToolCell {
  kind: "tool";
  id: string;
  toolCallId: string;
  toolName: string;
  args: unknown;
  status: "running" | "done" | "error";
  result?: unknown;
}

/** An extension_ui_request awaiting (or after) the user's answer. */
export interface QuestionCell {
  kind: "question";
  id: string;
  requestId: string;
  method: string;
  title: string;
  message?: string;
  options?: string[];
  placeholder?: string;
  answered: boolean;
}

export type TranscriptCell = UserCell | AssistantCell | ToolCell | QuestionCell;

export type AgentStatus = "idle" | "running";

export type DomainEvent =
  | { type: "cell_open"; cell: TranscriptCell }
  | {
      type: "cell_delta";
      cellId: string;
      contentIndex: number;
      blockKind: BlockKind;
      delta: string;
    }
  | { type: "block_end"; cellId: string; contentIndex: number; content: string }
  | { type: "tool_update"; cellId: string; partialResult: unknown }
  | { type: "tool_end"; cellId: string; status: "done" | "error"; result: unknown }
  | { type: "question_answered"; cellId: string }
  | { type: "cell_final"; cell: TranscriptCell }
  | { type: "agent_status"; status: AgentStatus };

export interface TranscriptState {
  cells: TranscriptCell[];
  agentStatus: AgentStatus;
}

export function emptyTranscript(): TranscriptState {
  return { cells: [], agentStatus: "idle" };
}

function upsertCell(cells: TranscriptCell[], cell: TranscriptCell): TranscriptCell[] {
  const index = cells.findIndex((c) => c.id === cell.id);
  if (index === -1) return [...cells, cell];
  const next = cells.slice();
  next[index] = cell;
  return next;
}

function updateAssistant(
  cells: TranscriptCell[],
  cellId: string,
  update: (cell: AssistantCell) => AssistantCell,
): TranscriptCell[] {
  const index = cells.findIndex((c) => c.id === cellId);
  const cell = index === -1 ? undefined : cells[index];
  if (!cell || cell.kind !== "assistant") return cells;
  const next = cells.slice();
  next[index] = update(cell);
  return next;
}

/**
 * Pure reducer. Deltas accumulate block text; `cell_final` REPLACES the whole
 * cell with authoritative content, so a lost delta can never corrupt the
 * durable transcript (self-healing).
 */
export function reduceTranscript(state: TranscriptState, event: DomainEvent): TranscriptState {
  switch (event.type) {
    case "agent_status":
      return { ...state, agentStatus: event.status };
    case "cell_open":
    case "cell_final":
      return { ...state, cells: upsertCell(state.cells, event.cell) };
    case "cell_delta":
      return {
        ...state,
        cells: updateAssistant(state.cells, event.cellId, (cell) => {
          const blocks = cell.blocks.slice();
          const blockIndex = blocks.findIndex((b) => b.contentIndex === event.contentIndex);
          const existing = blockIndex === -1 ? undefined : blocks[blockIndex];
          if (existing) {
            blocks[blockIndex] = { ...existing, text: existing.text + event.delta };
          } else {
            // Self-healing: a delta for an unseen block opens it implicitly.
            blocks.push({
              kind: event.blockKind,
              contentIndex: event.contentIndex,
              text: event.delta,
              done: false,
            });
          }
          return { ...cell, blocks };
        }),
      };
    case "block_end":
      return {
        ...state,
        cells: updateAssistant(state.cells, event.cellId, (cell) => ({
          ...cell,
          blocks: cell.blocks.map((b) =>
            b.contentIndex === event.contentIndex ? { ...b, text: event.content, done: true } : b,
          ),
        })),
      };
    case "tool_update": {
      const index = state.cells.findIndex((c) => c.id === event.cellId);
      const cell = index === -1 ? undefined : state.cells[index];
      if (!cell || cell.kind !== "tool") return state;
      const next = state.cells.slice();
      next[index] = { ...cell, result: event.partialResult };
      return { ...state, cells: next };
    }
    case "tool_end": {
      const index = state.cells.findIndex((c) => c.id === event.cellId);
      const cell = index === -1 ? undefined : state.cells[index];
      if (!cell || cell.kind !== "tool") return state;
      const next = state.cells.slice();
      // Merge, don't replace: tool_execution_end carries no args.
      next[index] = { ...cell, status: event.status, result: event.result };
      return { ...state, cells: next };
    }
    case "question_answered": {
      const index = state.cells.findIndex((c) => c.id === event.cellId);
      const cell = index === -1 ? undefined : state.cells[index];
      if (!cell || cell.kind !== "question") return state;
      const next = state.cells.slice();
      next[index] = { ...cell, answered: true };
      return { ...state, cells: next };
    }
  }
}
