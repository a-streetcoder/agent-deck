import { useState } from "react";
import {
  memoryToolCardLabel,
  type QuestionCell,
  type SubagentCell,
  type ToolCell,
  type TranscriptCell,
} from "@agent-deck/domain";
import { balance } from "@/design-system/markdown/balancer";
import { MessageBubble } from "@/components/transcript/MessageBubble";
import { ToolGroupCard, type ToolGroupStatus } from "@/components/transcript/ToolGroupCard";
import { sendUiResponse } from "../state/wsBridge.ts";

const TOOL_STATUS: Record<ToolCell["status"], ToolGroupStatus> = {
  running: "running",
  done: "result",
  error: "failed",
};

function ToolCellView({ cell }: { cell: ToolCell }) {
  const argsText =
    cell.args === undefined ? null : (
      <pre className="overflow-x-auto whitespace-pre-wrap font-mono text-xs text-text-muted">
        {typeof cell.args === "string" ? cell.args : JSON.stringify(cell.args, null, 2)}
      </pre>
    );
  const resultText =
    cell.result === undefined ? null : (
      <pre className="max-h-64 overflow-auto whitespace-pre-wrap font-mono text-xs text-text-secondary">
        {typeof cell.result === "string" ? cell.result : JSON.stringify(cell.result, null, 2)}
      </pre>
    );
  // Agent Deck memory tools render as native "Memory Stored / Searched / …"
  // cards (Brain icon, friendly label) instead of the raw tool name.
  const memoryLabel = memoryToolCardLabel(cell);
  return (
    <div data-testid="tool-cell" data-memory-card={memoryLabel ?? undefined}>
      <ToolGroupCard
        name={memoryLabel ?? cell.toolName}
        variant={memoryLabel ? "memory" : "generic"}
        status={TOOL_STATUS[cell.status]}
        defaultExpanded={cell.status === "running"}
        body={
          <div className="space-y-2">
            {argsText}
            {resultText}
          </div>
        }
      />
    </div>
  );
}

const SUBAGENT_STATUS: Record<SubagentCell["status"], ToolGroupStatus> = {
  running: "running",
  done: "result",
  error: "failed",
};

/**
 * A native subagent run streamed into the parent transcript (managed_subagent /
 * managed_parallel). The child's task and its live/authoritative output render
 * in an expandable card, mirroring the native "agent block".
 */
function SubagentCellView({ cell }: { cell: SubagentCell }) {
  return (
    <div data-testid="subagent-cell" data-status={cell.status}>
      <ToolGroupCard
        name="Subagent"
        variant="generic"
        status={SUBAGENT_STATUS[cell.status]}
        defaultExpanded={cell.status === "running"}
        body={
          <div className="space-y-2">
            <div className="text-xs font-medium uppercase tracking-wide text-text-muted">Task</div>
            <div className="whitespace-pre-wrap text-xs text-text-muted">{cell.task}</div>
            {cell.progress.length > 0 ? (
              <ul className="space-y-1" data-testid="subagent-progress">
                {cell.progress.map((message, index) => (
                  <li
                    key={index}
                    className="flex gap-1.5 text-xs text-text-muted"
                    data-testid="subagent-progress-item"
                  >
                    <span aria-hidden>→</span>
                    <span className="whitespace-pre-wrap">{message}</span>
                  </li>
                ))}
              </ul>
            ) : null}
            {cell.text ? (
              <div
                className="max-h-64 overflow-auto whitespace-pre-wrap text-xs text-text-secondary"
                data-testid="subagent-output"
              >
                {cell.text}
              </div>
            ) : null}
          </div>
        }
      />
    </div>
  );
}

function QuestionCellView({ cell }: { cell: QuestionCell }) {
  const [inputValue, setInputValue] = useState(
    cell.method === "editor" ? (cell.prefill ?? "") : "",
  );
  const answer = (response: Record<string, unknown>): void =>
    sendUiResponse(cell.requestId, response);

  return (
    <div
      className="rounded-xl border px-4 py-3"
      style={{
        borderColor: "var(--color-selection-stroke)",
        background: "var(--color-selection-fill)",
      }}
      data-testid="question-cell"
      data-answered={cell.answered ? "true" : "false"}
    >
      <div className="font-medium text-text-primary" style={{ fontStretch: "expanded" }}>
        {cell.title}
      </div>
      {cell.message ? <div className="mt-1 text-sm text-text-secondary">{cell.message}</div> : null}
      {cell.answered ? (
        <div className="mt-2 text-sm text-text-muted">Answered.</div>
      ) : cell.method === "confirm" ? (
        <div className="mt-3 flex gap-2">
          <button
            data-testid="question-confirm-yes"
            className="rounded-capsule bg-primary px-4 py-1.5 text-sm font-medium"
            style={{ color: "var(--color-accent-foreground)" }}
            onClick={() => answer({ confirmed: true })}
          >
            Yes
          </button>
          <button
            data-testid="question-confirm-no"
            className="rounded-capsule border border-border-strong px-4 py-1.5 text-sm text-text-secondary"
            onClick={() => answer({ confirmed: false })}
          >
            No
          </button>
        </div>
      ) : cell.method === "select" ? (
        <div className="mt-3 flex flex-wrap gap-2">
          {(cell.options ?? []).map((option) => (
            <button
              key={option}
              data-testid={`question-option-${option}`}
              className="rounded-capsule border border-border-strong px-3 py-1.5 text-sm text-text-primary hover:border-accent"
              onClick={() => answer({ value: option })}
            >
              {option}
            </button>
          ))}
        </div>
      ) : cell.method === "editor" ? (
        <div className="mt-3 flex flex-col gap-2">
          <textarea
            data-testid="question-editor"
            aria-label={cell.title}
            className="min-h-[7rem] resize-y rounded-md border border-border-strong bg-surface px-2 py-1.5 font-mono text-sm text-text-primary outline-none focus:border-accent"
            placeholder={cell.placeholder}
            value={inputValue}
            onChange={(event) => setInputValue(event.target.value)}
          />
          <button
            data-testid="question-submit"
            className="self-end rounded-capsule bg-primary px-3 py-1.5 text-sm font-medium"
            style={{ color: "var(--color-accent-foreground)" }}
            onClick={() => answer({ value: inputValue })}
          >
            Send
          </button>
        </div>
      ) : (
        <div className="mt-3 flex gap-2">
          <input
            data-testid="question-input"
            aria-label={cell.title}
            className="flex-1 rounded-md border border-border-strong bg-surface px-2 py-1.5 text-sm text-text-primary outline-none focus:border-accent"
            placeholder={cell.placeholder}
            value={inputValue}
            onChange={(event) => setInputValue(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") answer({ value: inputValue });
            }}
          />
          <button
            data-testid="question-submit"
            className="rounded-capsule bg-primary px-3 py-1.5 text-sm font-medium"
            style={{ color: "var(--color-accent-foreground)" }}
            onClick={() => answer({ value: inputValue })}
          >
            Send
          </button>
        </div>
      )}
      {!cell.answered ? (
        <button
          className="mt-2 text-xs text-text-muted hover:text-text-primary"
          onClick={() => answer({ cancelled: true })}
        >
          Cancel
        </button>
      ) : null}
    </div>
  );
}

export function CellView({ cell }: { cell: TranscriptCell }) {
  switch (cell.kind) {
    case "user":
      return (
        <div className="flex justify-end" data-testid="user-cell">
          <MessageBubble role="user" text={cell.text} className="max-w-[80%]" />
        </div>
      );
    case "assistant":
      return (
        <div
          className="space-y-2"
          data-testid="assistant-cell"
          data-streaming={cell.streaming ? "true" : "false"}
        >
          {cell.blocks.map((block) =>
            block.kind === "thinking" ? (
              <MessageBubble
                key={block.contentIndex}
                role="thinking"
                text={block.done ? block.text : balance(block.text)}
              />
            ) : (
              <div key={block.contentIndex} data-testid="assistant-text">
                <MessageBubble
                  role="assistant"
                  text={block.done ? block.text : balance(block.text)}
                />
              </div>
            ),
          )}
          {cell.errorMessage ? <MessageBubble role="error" text={cell.errorMessage} /> : null}
        </div>
      );
    case "tool":
      return <ToolCellView cell={cell} />;
    case "subagent":
      return <SubagentCellView cell={cell} />;
    case "question":
      return <QuestionCellView cell={cell} />;
  }
}
