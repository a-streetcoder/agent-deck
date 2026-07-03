import type { AssistantCell, ToolCell, TranscriptCell, UserCell } from "@agent-deck/domain";

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

export function CellView({ cell }: { cell: TranscriptCell }) {
  switch (cell.kind) {
    case "user":
      return <UserCellView cell={cell} />;
    case "assistant":
      return <AssistantCellView cell={cell} />;
    case "tool":
      return <ToolCellView cell={cell} />;
  }
}
