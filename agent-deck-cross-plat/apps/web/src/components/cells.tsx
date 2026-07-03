import { useState } from "react";
import type {
  AssistantCell,
  QuestionCell,
  ToolCell,
  TranscriptCell,
  UserCell,
} from "@agent-deck/domain";
import { sendUiResponse } from "../state/wsBridge.ts";

function UserCellView({ cell }: { cell: UserCell }) {
  return (
    <div className="flex justify-end" data-testid="user-cell">
      <div className="max-w-[80%] whitespace-pre-wrap rounded-lg bg-[var(--color-surface-subtle)] px-4 py-2.5 text-text-primary">
        {cell.text}
      </div>
    </div>
  );
}

function AssistantCellView({ cell }: { cell: AssistantCell }) {
  return (
    <div
      className="border-l-2 pl-4"
      style={{ borderColor: "var(--color-role-assistant)" }}
      data-testid="assistant-cell"
      data-streaming={cell.streaming ? "true" : "false"}
    >
      {cell.blocks.map((block) =>
        block.kind === "thinking" ? (
          <details key={block.contentIndex} className="mb-2">
            <summary
              className="cursor-pointer text-sm"
              style={{ color: "var(--color-role-thinking)" }}
            >
              Thinking
            </summary>
            <div className="whitespace-pre-wrap text-sm text-text-muted">{block.text}</div>
          </details>
        ) : (
          <div
            key={block.contentIndex}
            className="whitespace-pre-wrap text-text-primary"
            data-testid="assistant-text"
          >
            {block.text}
          </div>
        ),
      )}
      {cell.errorMessage ? (
        <div className="mt-2 text-sm" style={{ color: "var(--color-role-error)" }}>
          {cell.errorMessage}
        </div>
      ) : null}
      {cell.streaming && cell.blocks.length === 0 ? (
        <div className="animate-pulse text-text-muted">…</div>
      ) : null}
    </div>
  );
}

function ToolCellView({ cell }: { cell: ToolCell }) {
  const statusColor =
    cell.status === "error"
      ? "var(--color-role-error)"
      : cell.status === "running"
        ? "var(--color-role-status)"
        : "var(--color-role-tool)";
  return (
    <div
      className="rounded-md border border-border-subtle bg-surface-elevated px-3 py-2 font-mono text-sm"
      data-testid="tool-cell"
    >
      <div style={{ color: statusColor }}>
        {cell.toolName}
        {cell.status === "running" ? " …" : ""}
      </div>
      {cell.result !== undefined ? (
        <pre className="mt-1 max-h-48 overflow-auto whitespace-pre-wrap text-text-secondary">
          {typeof cell.result === "string" ? cell.result : JSON.stringify(cell.result, null, 2)}
        </pre>
      ) : null}
    </div>
  );
}

function QuestionCellView({ cell }: { cell: QuestionCell }) {
  const [inputValue, setInputValue] = useState("");
  const answer = (response: Record<string, unknown>): void =>
    sendUiResponse(cell.requestId, response);

  return (
    <div
      className="rounded-lg border px-4 py-3"
      style={{ borderColor: "var(--color-brand-accent)" }}
      data-testid="question-cell"
      data-answered={cell.answered ? "true" : "false"}
    >
      <div className="font-medium text-text-primary">{cell.title}</div>
      {cell.message ? <div className="mt-1 text-sm text-text-secondary">{cell.message}</div> : null}
      {cell.answered ? (
        <div className="mt-2 text-sm text-text-muted">Answered.</div>
      ) : cell.method === "confirm" ? (
        <div className="mt-3 flex gap-2">
          <button
            data-testid="question-confirm-yes"
            className="rounded-md bg-primary px-4 py-1.5 text-sm font-medium"
            style={{ color: "var(--color-accent-foreground)" }}
            onClick={() => answer({ confirmed: true })}
          >
            Yes
          </button>
          <button
            data-testid="question-confirm-no"
            className="rounded-md border border-border-strong px-4 py-1.5 text-sm text-text-secondary"
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
              className="rounded-md border border-border-strong px-3 py-1.5 text-sm text-text-primary hover:border-accent"
              onClick={() => answer({ value: option })}
            >
              {option}
            </button>
          ))}
        </div>
      ) : (
        <div className="mt-3 flex gap-2">
          <input
            data-testid="question-input"
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
            className="rounded-md bg-primary px-3 py-1.5 text-sm font-medium"
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
      return <UserCellView cell={cell} />;
    case "assistant":
      return <AssistantCellView cell={cell} />;
    case "tool":
      return <ToolCellView cell={cell} />;
    case "question":
      return <QuestionCellView cell={cell} />;
  }
}
