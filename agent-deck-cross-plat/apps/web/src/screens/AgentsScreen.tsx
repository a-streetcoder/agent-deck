import { useMemo, useState } from "react";
import { Pencil, Power, PowerOff, Plus, Star, Trash2 } from "lucide-react";
import {
  agentMatchesFilter,
  AGENT_FILTERS,
  type AgentFilter,
  type AgentInfo,
} from "@agent-deck/domain";
import { cn } from "@/lib/cn";
import { MarkdownDocument } from "@/design-system/markdown/MarkdownDocument";
import { useAgents } from "../state/useAgents.ts";
import { useAppStore } from "../state/store.ts";
import { deleteAgent, setAgentDisabled, updateProject } from "../state/wsBridge.ts";
import { AgentAvatar, agentSourceColor } from "../components/agents/AgentAvatar.tsx";
import { AgentEditSheet } from "../components/agents/AgentEditSheet.tsx";
import { ScopeChip } from "../components/ScopeChip.tsx";

/**
 * Native AgentsScreen: a fixed master-detail split (list 42% / detail 58%,
 * AppTheme.Split.listFraction) — sectioned avatar rows on the left, an
 * AppPage-style detail on the right, editing in a tabbed sheet.
 */

const SECTION_ORDER: Array<{ scope: AgentInfo["scope"]; title: string; hint?: string }> = [
  { scope: "project", title: "Project Agents" },
  { scope: "global", title: "Global Agents", hint: "available everywhere" },
  { scope: "library", title: "Library Agents" },
  { scope: "builtin", title: "Builtin Agents", hint: "bundled with Agent Deck" },
];

function AgentRow({
  agent,
  selected,
  onSelect,
  onEdit,
}: {
  agent: AgentInfo;
  selected: boolean;
  onSelect: () => void;
  onEdit: () => void;
}) {
  return (
    <div
      className={cn(
        "group flex cursor-pointer items-center gap-3 rounded-xl border px-3 py-2 transition-colors",
        "focus-visible:outline focus-visible:outline-2 focus-visible:outline-[var(--color-brand-accent)]",
        selected
          ? "border-[var(--color-selection-stroke)] bg-[var(--color-selection-fill)]"
          : "border-transparent hover:bg-[var(--color-hover-fill)]",
        (agent.shadowed || agent.disabled) && "opacity-60 saturate-50",
      )}
      data-testid="agent-row"
      data-agent-name={agent.name}
      role="option"
      aria-selected={selected}
      tabIndex={0}
      onClick={onSelect}
      onKeyDown={(event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          onSelect();
        }
      }}
    >
      <AgentAvatar agent={agent} />
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <span
            className="truncate text-sm font-semibold text-text-primary"
            style={{ fontStretch: "expanded" }}
          >
            {agent.name}
          </span>
          <ScopeChip scope={agent.scope} />
          {agent.disabled ? (
            <span
              className="rounded-capsule border px-1.5 text-[10px]"
              style={{
                color: "var(--color-text-muted)",
                borderColor: "var(--color-border-strong)",
              }}
              data-testid="disabled-badge"
            >
              disabled
            </span>
          ) : null}
          {agent.overridden ? (
            <span
              className="text-[10px]"
              style={{ color: "var(--color-warning)" }}
              data-testid="overridden-badge"
            >
              overridden
            </span>
          ) : null}
          {agent.shadowed ? <span className="text-[10px] text-text-muted">shadowed</span> : null}
        </div>
        {agent.description ? (
          <div className="line-clamp-2 text-xs text-text-secondary">{agent.description}</div>
        ) : null}
      </div>
      {/* Hover-reveal Edit pill (native AgentListRow). Library agents are
          read-only catalog entries — no writable target exists for them. */}
      {agent.scope !== "library" ? (
        <button
          data-testid={`agent-row-edit-${agent.name}`}
          className="rounded-capsule border border-border-strong px-2.5 py-1 text-xs text-text-secondary opacity-0 transition-opacity hover:text-text-primary focus-visible:opacity-100 group-hover:opacity-100"
          onClick={(event) => {
            event.stopPropagation();
            onEdit();
          }}
        >
          Edit
        </button>
      ) : null}
    </div>
  );
}

function ChipList({ label, items }: { label: string; items: string[] | undefined }) {
  if (!items?.length) return null;
  return (
    <div>
      <div className="pb-1 text-[10px] font-semibold uppercase tracking-wider text-text-muted">
        {label}
      </div>
      <div className="flex flex-wrap gap-1.5">
        {items.map((item) => (
          <span
            key={item}
            className="rounded-capsule border border-border-subtle bg-surface px-2 py-0.5 font-mono text-[11px] text-text-secondary"
          >
            {item}
          </span>
        ))}
      </div>
    </div>
  );
}

function AgentDetail({ agent, onEdit }: { agent: AgentInfo; onEdit: () => void }) {
  const projects = useAppStore((state) => state.projects);
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const currentProject = projects.find((p) => p.id === currentProjectId);
  const isDefault = currentProject?.defaultAgentName === agent.name;

  return (
    <div className="min-h-0 flex-1 overflow-y-auto px-6 py-5" data-testid="agent-detail">
      <div className="flex items-start gap-4">
        <AgentAvatar agent={agent} size={56} />
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2">
            <h2
              className="truncate text-xl font-bold text-text-primary"
              style={{ fontStretch: "expanded" }}
            >
              {agent.name}
            </h2>
            <ScopeChip scope={agent.scope} />
            {agent.replacesBuiltin ? (
              <span className="text-xs" style={{ color: "var(--color-warning)" }}>
                replaces builtin
              </span>
            ) : null}
          </div>
          {agent.description ? (
            <p className="mt-0.5 text-sm text-text-secondary">{agent.description}</p>
          ) : null}
        </div>
        <div className="flex shrink-0 items-center gap-2">
          {currentProject && !agent.shadowed ? (
            <button
              data-testid={`default-agent-${agent.name}`}
              className={cn(
                "flex items-center gap-1.5 rounded-capsule border px-2.5 py-1 text-xs",
                isDefault
                  ? "border-[var(--color-brand-accent)] text-[var(--color-brand-accent)]"
                  : "border-border-strong text-text-muted hover:text-text-primary",
              )}
              onClick={() =>
                void updateProject(currentProject.id, {
                  defaultAgentName: isDefault ? null : agent.name,
                })
              }
            >
              <Star size={12} fill={isDefault ? "currentColor" : "none"} />
              {isDefault ? "project default" : "make default"}
            </button>
          ) : null}
          {agent.scope !== "library" ? (
            <>
              <button
                data-testid="agent-disable"
                className="flex items-center gap-1.5 rounded-capsule border border-border-strong px-2.5 py-1 text-xs text-text-secondary hover:text-text-primary"
                onClick={() => void setAgentDisabled(agent.scope, agent.name, !agent.disabled)}
              >
                {agent.disabled ? <Power size={12} /> : <PowerOff size={12} />}
                {agent.disabled ? "Enable" : "Disable"}
              </button>
              <button
                data-testid="agent-edit"
                className="flex items-center gap-1.5 rounded-capsule px-3 py-1 text-xs font-medium shadow-capsule"
                style={{
                  background:
                    "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
                  color: "var(--color-accent-foreground)",
                }}
                onClick={onEdit}
              >
                <Pencil size={12} />
                Edit
              </button>
              {/* Delete removes a custom agent's file. Builtins are bundled
                  and can only be reset — offered just when overridden, so its
                  effect ("clear all overrides") is unambiguous. */}
              {agent.scope !== "builtin" ? (
                <button
                  data-testid="agent-delete"
                  className="rounded-capsule border border-border-strong p-1.5 text-text-muted hover:text-[var(--color-role-error)]"
                  title="Delete agent"
                  onClick={() => {
                    if (confirm(`Delete agent "${agent.name}"? This removes its file.`)) {
                      void deleteAgent(agent.scope, agent.name);
                    }
                  }}
                >
                  <Trash2 size={13} />
                </button>
              ) : agent.overridden ? (
                <button
                  data-testid="agent-reset"
                  className="rounded-capsule border border-border-strong px-2.5 py-1 text-xs text-text-muted hover:text-[var(--color-role-error)]"
                  title="Clear all overrides and restore the bundled defaults"
                  onClick={() => {
                    if (
                      confirm(`Reset "${agent.name}" — clear all overrides and restore defaults?`)
                    ) {
                      void deleteAgent(agent.scope, agent.name);
                    }
                  }}
                >
                  Reset
                </button>
              ) : null}
            </>
          ) : null}
        </div>
      </div>

      <div className="mt-5 space-y-4">
        {agent.whenToUse ? (
          <div className="rounded-xl border border-border-subtle bg-surface-elevated px-4 py-3">
            <div className="pb-1 text-[10px] font-semibold uppercase tracking-wider text-text-muted">
              When to use
            </div>
            <p className="text-sm text-text-secondary">{agent.whenToUse}</p>
          </div>
        ) : null}

        <div className="rounded-xl border border-border-subtle bg-surface-elevated px-4 py-3">
          <div className="pb-2 text-[10px] font-semibold uppercase tracking-wider text-text-muted">
            System prompt
          </div>
          <MarkdownDocument source={agent.body || "_(empty — pi's default prompt applies)_"} />
        </div>

        <div className="grid grid-cols-2 gap-4">
          <div className="rounded-xl border border-border-subtle bg-surface-elevated px-4 py-3">
            <ChipList label="Tools" items={agent.tools ?? ["pi defaults"]} />
          </div>
          <div className="rounded-xl border border-border-subtle bg-surface-elevated px-4 py-3">
            <ChipList label="Skills" items={agent.skills?.length ? agent.skills : ["none"]} />
          </div>
        </div>

        <div className="grid grid-cols-2 gap-4 text-xs text-text-muted">
          <div>
            model: <span className="font-mono">{agent.model ?? "pi default"}</span>
            {agent.thinking ? <span className="font-mono">:{agent.thinking}</span> : null}
          </div>
          <div className="truncate" title={agent.filePath}>
            {agent.filePath}
          </div>
        </div>
      </div>
    </div>
  );
}

export function AgentsScreen() {
  const agents = useAgents();
  const [filter, setFilter] = useState<AgentFilter>("all");
  const [search, setSearch] = useState("");
  const [selectedKey, setSelectedKey] = useState<string | null>(null);
  const [editing, setEditing] = useState<AgentInfo | null | "new">(null);

  const visible = useMemo(() => {
    const query = search.trim().toLowerCase();
    return agents.filter(
      (agent) =>
        agentMatchesFilter(agent, filter) &&
        (query === "" ||
          agent.name.toLowerCase().includes(query) ||
          (agent.description ?? "").toLowerCase().includes(query)),
    );
  }, [agents, filter, search]);

  const selected =
    visible.find((a) => a.filePath === selectedKey) ??
    visible.find((a) => !a.shadowed) ??
    visible[0] ??
    null;

  return (
    <div className="flex min-h-0 flex-1" data-testid="agents-screen">
      {/* List pane — native fixed 42% split. */}
      <div className="flex w-[42%] min-w-[320px] flex-col border-r border-border-subtle">
        <div className="space-y-2 px-3 pb-2 pt-3">
          <div className="flex items-center gap-2">
            <input
              data-testid="agent-search"
              className="min-w-0 flex-1 rounded-lg border border-border-strong bg-surface px-2.5 py-1.5 text-sm text-text-primary outline-none focus:border-accent"
              placeholder="Search agents"
              value={search}
              onChange={(event) => setSearch(event.target.value)}
            />
            <button
              data-testid="new-agent"
              className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full shadow-capsule"
              style={{
                background:
                  "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
                color: "var(--color-accent-foreground)",
              }}
              title="New agent"
              onClick={() => setEditing("new")}
            >
              <Plus size={15} />
            </button>
          </div>
          <div className="flex flex-wrap gap-1">
            {AGENT_FILTERS.map((f) => (
              <button
                key={f}
                data-testid={`agent-filter-${f}`}
                className={cn(
                  "rounded-capsule px-2.5 py-0.5 text-xs",
                  filter === f
                    ? "bg-[var(--color-selection-fill)] text-text-primary"
                    : "text-text-muted hover:bg-[var(--color-hover-fill)]",
                )}
                onClick={() => setFilter(f)}
              >
                {f}
              </button>
            ))}
          </div>
        </div>
        <div
          className="min-h-0 flex-1 space-y-3 overflow-y-auto px-3 pb-4"
          role="listbox"
          aria-label="Agents"
        >
          {SECTION_ORDER.map(({ scope, title, hint }) => {
            const sectionAgents = visible.filter((agent) => agent.scope === scope);
            if (sectionAgents.length === 0) return null;
            return (
              <div key={scope}>
                <div className="flex items-baseline gap-2 px-1 pb-1 pt-2">
                  <span
                    className="text-[10px] font-semibold uppercase tracking-wider"
                    style={{ color: agentSourceColor({ scope }) }}
                  >
                    {title}
                  </span>
                  {hint ? <span className="text-[10px] text-text-muted">{hint}</span> : null}
                </div>
                <div className="space-y-1">
                  {sectionAgents.map((agent) => (
                    <AgentRow
                      key={agent.filePath}
                      agent={agent}
                      selected={selected?.filePath === agent.filePath}
                      onSelect={() => setSelectedKey(agent.filePath)}
                      onEdit={() => {
                        setSelectedKey(agent.filePath);
                        setEditing(agent);
                      }}
                    />
                  ))}
                </div>
              </div>
            );
          })}
          {visible.length === 0 ? (
            <div className="mt-8 text-center text-sm text-text-muted">
              No agents match this filter.
            </div>
          ) : null}
        </div>
      </div>

      {/* Detail pane */}
      {selected ? (
        <AgentDetail agent={selected} onEdit={() => setEditing(selected)} />
      ) : (
        <div className="flex flex-1 items-center justify-center text-sm text-text-muted">
          Select an agent.
        </div>
      )}

      {editing !== null ? (
        <AgentEditSheet
          agent={editing === "new" ? null : editing}
          onClose={() => setEditing(null)}
        />
      ) : null}
    </div>
  );
}
