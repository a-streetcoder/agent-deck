import { useState } from "react";
import { agentMatchesFilter, AGENT_FILTERS, type AgentFilter } from "@agent-deck/domain";
import { useAgents } from "../state/useAgents.ts";
import { ScopeChip } from "../components/ScopeChip.tsx";

export function AgentsScreen() {
  const agents = useAgents();
  const [filter, setFilter] = useState<AgentFilter>("all");

  const visible = agents.filter((agent) => agentMatchesFilter(agent, filter));

  return (
    <div className="flex-1 overflow-y-auto px-6 py-4" data-testid="agents-screen">
      <div className="mb-4 flex flex-wrap gap-2">
        {AGENT_FILTERS.map((f) => (
          <button
            key={f}
            data-testid={`agent-filter-${f}`}
            className={`rounded-capsule px-3 py-1 text-sm ${
              filter === f
                ? "bg-[var(--color-selection-fill)] text-text-primary"
                : "text-text-muted hover:bg-[var(--color-hover-fill)]"
            }`}
            onClick={() => setFilter(f)}
          >
            {f}
          </button>
        ))}
      </div>
      <div className="space-y-2">
        {visible.map((agent) => (
          <div
            key={agent.filePath}
            className="rounded-lg border border-border-subtle bg-surface-elevated px-4 py-3"
            data-testid="agent-row"
            data-agent-name={agent.name}
            style={agent.shadowed ? { opacity: 0.55 } : undefined}
          >
            <div className="flex items-center gap-2">
              <span className="font-medium text-text-primary">{agent.name}</span>
              <ScopeChip scope={agent.scope} />
              {agent.replacesBuiltin ? (
                <span className="text-xs" style={{ color: "var(--color-warning)" }}>
                  replaces builtin
                </span>
              ) : null}
              {agent.shadowed ? <span className="text-xs text-text-muted">shadowed</span> : null}
            </div>
            {agent.description ? (
              <div className="mt-1 text-sm text-text-secondary">{agent.description}</div>
            ) : null}
            {agent.tools ? (
              <div className="mt-1 font-mono text-xs text-text-muted">
                tools: {agent.tools.join(", ")}
              </div>
            ) : null}
          </div>
        ))}
        {visible.length === 0 ? (
          <div className="mt-8 text-center text-text-muted">No agents match this filter.</div>
        ) : null}
      </div>
    </div>
  );
}
