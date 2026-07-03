import { Composer } from "./components/Composer.tsx";
import { Transcript } from "./components/Transcript.tsx";
import { useAppStore } from "./state/store.ts";

export function App() {
  const connection = useAppStore((state) => state.connection);
  const agentStatus = useAppStore((state) => state.transcript.agentStatus);
  const session = useAppStore((state) => state.session);
  const error = useAppStore((state) => state.error);

  const statusLabel =
    connection !== "open" ? connection : agentStatus === "running" ? "responding" : "idle";
  const statusColor =
    connection !== "open"
      ? "var(--color-warning)"
      : agentStatus === "running"
        ? "var(--color-brand-accent)"
        : "var(--color-success)";

  return (
    <div className="flex h-full flex-col">
      <header className="flex items-center justify-between border-b border-border-subtle bg-surface-elevated px-6 py-3">
        <div className="flex items-baseline gap-3">
          <h1 className="font-pixel text-lg tracking-wide text-text-primary">AGENT DECK</h1>
          {session ? (
            <span className="max-w-[40ch] truncate font-mono text-xs text-text-muted">
              {session.cwd}
            </span>
          ) : null}
        </div>
        <div
          className="flex items-center gap-2"
          data-testid="status-indicator"
          data-status={statusLabel}
        >
          <span
            className="inline-block h-2.5 w-2.5 rounded-full"
            style={{ background: statusColor }}
          />
          <span className="text-sm text-text-secondary">{statusLabel}</span>
        </div>
      </header>
      {error ? (
        <div
          className="px-6 py-2 text-sm"
          style={{ background: "rgba(229,116,108,0.15)", color: "var(--color-role-error)" }}
          data-testid="error-banner"
        >
          {error}
        </div>
      ) : null}
      <Transcript />
      <Composer />
    </div>
  );
}
