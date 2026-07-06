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
  /** Initial text for the `editor` (multiline) method. */
  prefill?: string;
  answered: boolean;
}

/**
 * A native subagent run streamed into the PARENT transcript. The parent's
 * ManagedSession opens this when it launches a child pi (managed_subagent /
 * managed_parallel), appends the child's assistant text as it streams, and
 * finalizes it with the child's authoritative output. The tool result the model
 * receives is unaffected — this cell is purely the visible "Subagent" card.
 */
export interface SubagentCell {
  kind: "subagent";
  id: string;
  task: string;
  status: "running" | "done" | "error";
  text: string;
  /**
   * Non-blocking progress updates the child sent up its supervisor channel
   * (contact_supervisor → progress_update). Kept separate from `text` (the
   * child's assistant output) and preserved across finalization, since progress
   * arrives async while the child runs.
   */
  progress: string[];
  /** Run metadata, captured on completion (like the native PiSubagentRunRecord).
   * All optional — absent while running or if the provider doesn't report them. */
  model?: string;
  inputTokens?: number;
  outputTokens?: number;
  durationMs?: number;
}

/**
 * A BLOCKING supervisor request a child subagent raised via contact_supervisor
 * ({need_decision, interview_request}). The child is suspended until this is
 * answered; answering resolves the child's tool call with `answer` so it
 * continues. Rendered as an interactive card under the parent's Subagent card.
 */
export interface SupervisorQuestionCell {
  kind: "supervisor_question";
  id: string;
  requestId: string;
  /** The Subagent cell this request belongs to (for visual grouping). */
  subagentCellId: string;
  method: "need_decision" | "interview_request";
  title: string;
  message?: string;
  /** Suggested choices for need_decision; free text is always allowed. */
  options?: string[];
  answered: boolean;
  answer?: string;
  /** Resolved WITHOUT a human answer (the request timed out or the subagent
   * ended); the card is no longer interactive. `closedReason` says why. */
  closed?: boolean;
  closedReason?: string;
}

export type TranscriptCell =
  | UserCell
  | AssistantCell
  | ToolCell
  | QuestionCell
  | SubagentCell
  | SupervisorQuestionCell;

/**
 * A friendly transcript-card label for an Agent Deck memory bridge tool call
 * (native "Memory Stored / Searched / …" cards), or null for any other tool.
 * Pure so the web and any renderer agree on the label and it stays testable.
 */
export function memoryToolCardLabel(
  cell: Pick<ToolCell, "toolName" | "status" | "result">,
): string | null {
  if (!cell.toolName.startsWith("agent_deck_memory_")) return null;
  if (cell.toolName === "agent_deck_memory_search") return "Memory Searched";
  if (cell.toolName === "agent_deck_memory_mark_stale") return "Memory Marked Stale";
  if (cell.toolName === "agent_deck_memory_write") {
    const result = typeof cell.result === "string" ? cell.result : "";
    // Match the server's exact result-message PREFIXES, not a bare regex over
    // the whole string — the memory title is interpolated into the result
    // ("Stored memory <id>: <title>"), so a title containing "updated" or
    // "blocked" must not flip the label. Secret / no-project are isError; a held
    // near-duplicate comes back non-error with its guidance message.
    if (cell.status === "error" || result.startsWith("This looks like a near-duplicate")) {
      return "Memory Blocked";
    }
    if (result.startsWith("Updated memory ")) return "Memory Edited";
    return "Memory Stored";
  }
  return "Memory";
}

/**
 * A per-session activity plan (native activity-sidebar "Plan" card), driven by a
 * parent agent via the set_session_plan / update_session_plan bridge tools.
 */
export type PlanItemStatus = "todo" | "in_progress" | "done" | "blocked" | "skipped";

export interface SessionPlanItem {
  id: string;
  title: string;
  status: PlanItemStatus;
}

/** A patch to one plan item, addressed by id (title/status optional). */
export interface SessionPlanUpdate {
  id: string;
  title?: string;
  status?: PlanItemStatus;
}

export type AgentStatus = "idle" | "running";

/**
 * One native-subagent run as the deck/activity panel sees it — derived purely
 * from the transcript's subagent + supervisor cells (no separate server state in
 * v1). `needsInput` is true while a blocking supervisor request for this run is
 * still open (unanswered and not closed).
 */
export interface DeckRun {
  id: string;
  task: string;
  status: SubagentCell["status"];
  progressCount: number;
  needsInput: boolean;
  model?: string;
  inputTokens?: number;
  outputTokens?: number;
  durationMs?: number;
}

/**
 * Aggregate the session's subagent runs for the deck, in transcript order. Pure
 * so the web and any renderer agree and it stays unit-testable.
 */
export function deckRuns(state: TranscriptState): DeckRun[] {
  const openQuestions = state.cells.filter(
    (c): c is SupervisorQuestionCell =>
      c.kind === "supervisor_question" && !c.answered && !c.closed,
  );
  return state.cells
    .filter((c): c is SubagentCell => c.kind === "subagent")
    .map((cell) => ({
      id: cell.id,
      task: cell.task,
      status: cell.status,
      progressCount: cell.progress.length,
      needsInput: openQuestions.some((q) => q.subagentCellId === cell.id),
      model: cell.model,
      inputTokens: cell.inputTokens,
      outputTokens: cell.outputTokens,
      durationMs: cell.durationMs,
    }));
}

/** The full detail behind one deck run: its subagent cell + any supervisor
 * requests it raised (newest last, in transcript order). Pure — the deck's
 * expanded row and any renderer read the same shape. `cell` is undefined if the
 * id doesn't match a subagent cell. */
export interface DeckRunDetail {
  cell: SubagentCell | undefined;
  questions: SupervisorQuestionCell[];
}

export function deckRunDetail(state: TranscriptState, runId: string): DeckRunDetail {
  const cell = state.cells.find((c): c is SubagentCell => c.kind === "subagent" && c.id === runId);
  const questions = state.cells.filter(
    (c): c is SupervisorQuestionCell =>
      c.kind === "supervisor_question" && c.subagentCellId === runId,
  );
  return { cell, questions };
}

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
  | { type: "subagent_delta"; cellId: string; delta: string }
  | { type: "subagent_progress"; cellId: string; message: string }
  | { type: "supervisor_answered"; cellId: string; answer: string }
  | { type: "supervisor_closed"; cellId: string; reason: string }
  | { type: "question_answered"; cellId: string }
  | { type: "cell_final"; cell: TranscriptCell }
  | { type: "agent_status"; status: AgentStatus }
  | { type: "plan_set"; items: SessionPlanItem[] }
  | { type: "plan_update"; updates: SessionPlanUpdate[] };

export interface TranscriptState {
  cells: TranscriptCell[];
  agentStatus: AgentStatus;
  /** The session's activity plan (set_session_plan / update_session_plan). */
  plan: SessionPlanItem[];
}

export function emptyTranscript(): TranscriptState {
  return { cells: [], agentStatus: "idle", plan: [] };
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
    case "plan_set":
      // set_session_plan REPLACES the whole plan.
      return { ...state, plan: event.items };
    case "plan_update": {
      // update_session_plan patches items by id; unknown ids are ignored.
      const plan = state.plan.map((item) => {
        const patch = event.updates.find((u) => u.id === item.id);
        if (!patch) return item;
        return {
          ...item,
          ...(patch.title !== undefined ? { title: patch.title } : {}),
          ...(patch.status !== undefined ? { status: patch.status } : {}),
        };
      });
      return { ...state, plan };
    }
    case "cell_open":
      return { ...state, cells: upsertCell(state.cells, event.cell) };
    case "cell_final": {
      // Finalizing a subagent cell must not wipe its accumulated progress:
      // progress arrives async up the supervisor channel while the child runs,
      // and the finalizer (runChildAgent) doesn't have it. Carry it over.
      if (event.cell.kind === "subagent") {
        const prior = state.cells.find((c) => c.id === event.cell.id);
        if (prior?.kind === "subagent" && prior.progress.length > 0) {
          return {
            ...state,
            cells: upsertCell(state.cells, { ...event.cell, progress: prior.progress }),
          };
        }
      }
      return { ...state, cells: upsertCell(state.cells, event.cell) };
    }
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
    case "subagent_delta": {
      const index = state.cells.findIndex((c) => c.id === event.cellId);
      const cell = index === -1 ? undefined : state.cells[index];
      // Ignore deltas for an unknown/mismatched cell — cell_final replaces the
      // whole cell with the child's authoritative text, so a lost open or delta
      // can never corrupt the durable card (self-healing).
      if (!cell || cell.kind !== "subagent") return state;
      const next = state.cells.slice();
      next[index] = { ...cell, text: cell.text + event.delta };
      return { ...state, cells: next };
    }
    case "subagent_progress": {
      const index = state.cells.findIndex((c) => c.id === event.cellId);
      const cell = index === -1 ? undefined : state.cells[index];
      if (!cell || cell.kind !== "subagent") return state;
      const next = state.cells.slice();
      next[index] = { ...cell, progress: [...cell.progress, event.message] };
      return { ...state, cells: next };
    }
    case "supervisor_answered": {
      const index = state.cells.findIndex((c) => c.id === event.cellId);
      const cell = index === -1 ? undefined : state.cells[index];
      if (!cell || cell.kind !== "supervisor_question") return state;
      const next = state.cells.slice();
      next[index] = { ...cell, answered: true, answer: event.answer };
      return { ...state, cells: next };
    }
    case "supervisor_closed": {
      const index = state.cells.findIndex((c) => c.id === event.cellId);
      const cell = index === -1 ? undefined : state.cells[index];
      // A human answer wins over a close — don't overwrite an answered card.
      if (!cell || cell.kind !== "supervisor_question" || cell.answered) return state;
      const next = state.cells.slice();
      next[index] = { ...cell, closed: true, closedReason: event.reason };
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
