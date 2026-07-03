import { useState } from "react";
import {
  agentMatchesFilter,
  AGENT_FILTERS,
  type AgentFilter,
  type AgentInfo,
} from "@agent-deck/domain";
import { useAgents } from "../state/useAgents.ts";
import { useAppStore } from "../state/store.ts";
import { updateProject } from "../state/wsBridge.ts";
import { AgentEditor } from "../components/AgentEditor.tsx";
import { ScopeChip } from "../components/ScopeChip.tsx";

export function AgentsScreen() {
  const agents = useAgents();
  const projects = useAppStore((state) => state.projects);
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const currentProject = projects.find((p) => p.id === currentProjectId);
  const [filter, setFilter] = useState<AgentFilter>("all");
  const [editing, setEditing] = useState<AgentInfo | null | "new">(null);

  const visible = agents.filter((agent) => agentMatchesFilter(agent, filter));

  return (
    <div className="flex-1 overflow-y-auto px-6 py-4" data-testid="agents-screen">
      <div className="mb-4 flex flex-wrap items-center gap-2">
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
        <div className="flex-1" />
        <button
          data-testid="new-agent"
          className="rounded-md bg-primary px-3 py-1 text-sm font-medium"
          style={{ color: "var(--color-accent-foreground)" }}
          onClick={() => setEditing("new")}
        >
          New agent
        </button>
      </div>
      {editing !== null ? (
        <div className="mb-4">
          <AgentEditor
            agent={editing === "new" ? null : editing}
            onClose={() => setEditing(null)}
          />
        </div>
      ) : null}
      <div className="space-y-2">
        {visible.map((agent) => (
          <div
            key={agent.filePath}
            className="cursor-pointer rounded-lg border border-border-subtle bg-surface-elevated px-4 py-3 hover:border-border-strong"
            data-testid="agent-row"
            data-agent-name={agent.name}
            style={agent.shadowed ? { opacity: 0.55 } : undefined}
            onClick={() => setEditing(agent)}
          >
            <div className="flex items-center gap-2">
              <span className="font-medium text-text-primary">{agent.name}</span>
              <ScopeChip scope={agent.scope} />
              {agent.overridden ? (
                <span
                  className="text-xs"
                  style={{ color: "var(--color-warning)" }}
                  data-testid="overridden-badge"
                >
                  overridden
                </span>
              ) : null}
              {agent.replacesBuiltin ? (
                <span className="text-xs" style={{ color: "var(--color-warning)" }}>
                  replaces builtin
                </span>
              ) : null}
              {agent.shadowed ? <span className="text-xs text-text-muted">shadowed</span> : null}
              <div className="flex-1" />
              {currentProject && !agent.shadowed ? (
                <button
                  data-testid={`default-agent-${agent.name}`}
                  className="rounded-capsule px-2 py-0.5 text-xs"
                  style={
                    currentProject.defaultAgentName === agent.name
                      ? {
                          color: "var(--color-brand-accent)",
                          border: "1px solid var(--color-brand-accent)",
                        }
                      : {
                          color: "var(--color-text-muted)",
                          border: "1px solid var(--color-border-strong)",
                        }
                  }
                  onClick={(event) => {
                    event.stopPropagation();
                    void updateProject(currentProject.id, {
                      defaultAgentName:
                        currentProject.defaultAgentName === agent.name ? null : agent.name,
                    });
                  }}
                >
                  {currentProject.defaultAgentName === agent.name
                    ? "★ project default"
                    : "make default"}
                </button>
              ) : null}
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
