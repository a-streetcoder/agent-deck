import { useEffect, useRef, useState } from "react";
import { X } from "lucide-react";
import type { AgentInfo, ResourceScope } from "@agent-deck/domain";
import { cn } from "@/lib/cn";
import { useAppStore } from "../../state/store.ts";
import { AgentAvatar } from "./AgentAvatar.tsx";

/**
 * The native AgentEditSheet: a modal sheet with an AppSheetHeader (tinted
 * icon tile + title) and a Config / Prompt / Tools / Skills tab strip.
 */

type EditTab = "config" | "prompt" | "tools" | "skills" | "mcp";
const TABS: Array<{ id: EditTab; label: string }> = [
  { id: "config", label: "Config" },
  { id: "prompt", label: "Prompt" },
  { id: "tools", label: "Tools" },
  { id: "skills", label: "Skills" },
  { id: "mcp", label: "MCP" },
];

const inputClass =
  "w-full rounded-lg border border-border-strong bg-surface px-2.5 py-1.5 text-sm text-text-primary outline-none focus:border-accent";

const THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh"];

export function AgentEditSheet({
  agent,
  onClose,
}: {
  /** Existing agent, or null to create a new one. */
  agent: AgentInfo | null;
  onClose: () => void;
}) {
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const [tab, setTab] = useState<EditTab>("config");
  const [name, setName] = useState(agent?.name ?? "");
  const [scope, setScope] = useState<ResourceScope>(agent?.scope ?? "global");
  const [description, setDescription] = useState(agent?.description ?? "");
  const [whenToUse, setWhenToUse] = useState(agent?.whenToUse ?? "");
  const [model, setModel] = useState(agent?.model ?? "");
  const [thinking, setThinking] = useState(agent?.thinking ?? "");
  const [mode, setMode] = useState<"replace" | "append">(agent?.systemPromptMode ?? "replace");
  const [tools, setTools] = useState((agent?.tools ?? []).join(", "));
  const [skills, setSkills] = useState((agent?.skills ?? []).join(", "));
  const [mcpServers, setMcpServers] = useState((agent?.mcpServers ?? []).join(", "));
  const [body, setBody] = useState(agent?.body ?? "");
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const dialogRef = useRef<HTMLDivElement>(null);

  // Snapshot of the managed fields at open time — used both for dirty
  // detection (backdrop/Escape only dismiss when clean) and for the
  // conflict check before save.
  const initial = useRef({
    description: agent?.description ?? "",
    whenToUse: agent?.whenToUse ?? "",
    model: agent?.model ?? "",
    thinking: agent?.thinking ?? "",
    mode: agent?.systemPromptMode ?? "replace",
    tools: (agent?.tools ?? []).join(", "),
    skills: (agent?.skills ?? []).join(", "),
    mcpServers: (agent?.mcpServers ?? []).join(", "),
    body: agent?.body ?? "",
  }).current;
  const dirty =
    description !== initial.description ||
    whenToUse !== initial.whenToUse ||
    model !== initial.model ||
    thinking !== initial.thinking ||
    mode !== initial.mode ||
    tools !== initial.tools ||
    skills !== initial.skills ||
    mcpServers !== initial.mcpServers ||
    body !== initial.body ||
    (!agent && name.trim() !== "");

  const dirtyRef = useRef(dirty);
  dirtyRef.current = dirty;

  // Modal keyboard behavior: initial focus, Escape (when clean), focus trap.
  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    const focusables = (): HTMLElement[] =>
      [...dialog.querySelectorAll<HTMLElement>("button, input, select, textarea")].filter(
        (el) => !el.hasAttribute("disabled"),
      );
    focusables()[1]?.focus(); // first field after the close button
    const onKeyDown = (event: KeyboardEvent): void => {
      if (event.key === "Escape" && !dirtyRef.current) {
        event.stopPropagation();
        onClose();
        return;
      }
      if (event.key !== "Tab") return;
      const items = focusables();
      const first = items[0];
      const last = items[items.length - 1];
      if (!first || !last) return;
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };
    dialog.addEventListener("keydown", onKeyDown);
    return () => dialog.removeEventListener("keydown", onKeyDown);
  }, [onClose]);

  const isBuiltin = agent?.scope === "builtin";
  const parseList = (value: string): string[] =>
    value
      .split(",")
      .map((item) => item.trim())
      .filter(Boolean);

  const save = async (): Promise<void> => {
    setSaving(true);
    setError(null);
    try {
      if (agent) {
        // Conflict guard: the sheet sends complete form state, so refuse to
        // save when the agent changed on disk since the sheet opened.
        const query = currentProjectId ? `?projectId=${encodeURIComponent(currentProjectId)}` : "";
        const response = await fetch(`/resources/agents${query}`);
        if (response.ok) {
          const { agents } = (await response.json()) as { agents: AgentInfo[] };
          const live = agents.find((a) => a.name === agent.name && a.scope === agent.scope);
          if (
            live &&
            ((live.description ?? "") !== initial.description ||
              (live.whenToUse ?? "") !== initial.whenToUse ||
              (live.model ?? "") !== initial.model ||
              (live.thinking ?? "") !== initial.thinking ||
              live.systemPromptMode !== initial.mode ||
              (live.tools ?? []).join(", ") !== initial.tools ||
              (live.skills ?? []).join(", ") !== initial.skills ||
              (live.mcpServers ?? []).join(", ") !== initial.mcpServers ||
              live.body !== initial.body)
          ) {
            throw new Error(
              "This agent changed on disk while you were editing. Close the editor and reopen it to avoid overwriting those changes.",
            );
          }
        }
      }
      const response = await fetch("/resources/agents", {
        method: "PUT",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          projectId: currentProjectId ?? undefined,
          scope: agent ? agent.scope : scope,
          name: agent ? agent.name : name.trim(),
          edit: {
            description,
            whenToUse,
            model,
            thinking,
            systemPromptMode: mode,
            tools: parseList(tools),
            skills: parseList(skills),
            mcpServers: parseList(mcpServers),
            body,
          },
        }),
      });
      if (!response.ok) throw new Error(await response.text());
      onClose();
    } catch (err) {
      setError(String(err));
    } finally {
      setSaving(false);
    }
  };

  return (
    <div
      className="fixed inset-0 z-40 flex items-center justify-center bg-black/40 p-8"
      onMouseDown={(event) => {
        // Backdrop dismisses only while the form is clean — a stray press
        // must never discard edits (Cancel is the explicit path).
        if (event.target === event.currentTarget && !dirty) onClose();
      }}
    >
      <div
        ref={dialogRef}
        className="flex max-h-[85vh] w-[560px] flex-col rounded-2xl border border-border-strong bg-surface-elevated shadow-elevated"
        data-testid="agent-editor"
        role="dialog"
        aria-modal="true"
        aria-label={agent ? `Edit ${agent.name}` : "New agent"}
      >
        {/* Sheet header: tinted icon tile + title + Done (native AppSheetHeader). */}
        <div className="flex items-center gap-3 border-b border-border-subtle px-4 py-3">
          <AgentAvatar agent={agent ?? { scope, name }} size={32} />
          <div className="min-w-0 flex-1">
            <div
              className="truncate text-sm font-semibold text-text-primary"
              style={{ fontStretch: "expanded" }}
            >
              {agent ? `Edit ${agent.name}` : "New Agent"}
            </div>
            {isBuiltin ? (
              <div className="text-xs" style={{ color: "var(--color-warning)" }}>
                builtin — saved as override, file untouched
              </div>
            ) : null}
          </div>
          <button
            className="rounded-capsule p-1.5 text-text-muted hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
            aria-label="Close"
            onClick={onClose}
          >
            <X size={15} />
          </button>
        </div>

        {/* Tab strip */}
        <div className="flex gap-1 border-b border-border-subtle px-4 pt-2">
          {TABS.map((t) => (
            <button
              key={t.id}
              data-testid={`editor-tab-${t.id}`}
              className={cn(
                "rounded-t-lg px-3 py-1.5 text-xs font-medium",
                tab === t.id
                  ? "border border-b-0 border-border-subtle bg-surface text-text-primary"
                  : "text-text-muted hover:text-text-primary",
              )}
              style={{ fontStretch: "expanded" }}
              onClick={() => setTab(t.id)}
            >
              {t.label}
            </button>
          ))}
        </div>

        <div className="min-h-0 flex-1 space-y-3 overflow-y-auto p-4">
          {tab === "config" ? (
            <>
              {!agent ? (
                <div className="grid grid-cols-2 gap-3">
                  <label className="text-xs text-text-muted">
                    Name
                    <input
                      data-testid="editor-name"
                      className={inputClass}
                      value={name}
                      onChange={(e) => setName(e.target.value)}
                    />
                  </label>
                  <label className="text-xs text-text-muted">
                    Scope
                    <select
                      data-testid="editor-scope"
                      className={inputClass}
                      value={scope}
                      onChange={(e) => setScope(e.target.value as ResourceScope)}
                    >
                      <option value="global">global</option>
                      {currentProjectId ? <option value="project">project</option> : null}
                    </select>
                  </label>
                </div>
              ) : null}
              <label className="block text-xs text-text-muted">
                Description
                <input
                  data-testid="editor-description"
                  className={inputClass}
                  value={description}
                  onChange={(e) => setDescription(e.target.value)}
                />
              </label>
              <label className="block text-xs text-text-muted">
                When to use
                <input
                  className={inputClass}
                  value={whenToUse}
                  onChange={(e) => setWhenToUse(e.target.value)}
                />
              </label>
              <div className="grid grid-cols-2 gap-3">
                <label className="text-xs text-text-muted">
                  Model
                  <input
                    className={inputClass}
                    placeholder="Use Pi default"
                    value={model}
                    onChange={(e) => setModel(e.target.value)}
                  />
                </label>
                <label className="text-xs text-text-muted">
                  Thinking
                  <select
                    className={inputClass}
                    value={thinking}
                    onChange={(e) => setThinking(e.target.value)}
                  >
                    <option value="">Pi default</option>
                    {THINKING_LEVELS.map((level) => (
                      <option key={level} value={level}>
                        {level}
                      </option>
                    ))}
                  </select>
                </label>
              </div>
            </>
          ) : null}

          {tab === "prompt" ? (
            <>
              <label className="block text-xs text-text-muted">
                Prompt mode
                <select
                  className={inputClass}
                  value={mode}
                  onChange={(e) => setMode(e.target.value as "replace" | "append")}
                >
                  <option value="replace">Replace</option>
                  <option value="append">Append</option>
                </select>
              </label>
              <label className="block text-xs text-text-muted">
                System prompt (markdown)
                <textarea
                  data-testid="editor-body"
                  className={cn(inputClass, "min-h-[220px] font-mono text-[12px]")}
                  value={body}
                  onChange={(e) => setBody(e.target.value)}
                />
              </label>
            </>
          ) : null}

          {tab === "tools" ? (
            <label className="block text-xs text-text-muted">
              Tools (comma-separated; empty = pi defaults)
              <input
                data-testid="editor-tools"
                className={inputClass}
                placeholder="read, grep, bash…"
                value={tools}
                onChange={(e) => setTools(e.target.value)}
              />
            </label>
          ) : null}

          {tab === "skills" ? (
            <label className="block text-xs text-text-muted">
              Skills (comma-separated names from the catalog)
              <input
                className={inputClass}
                value={skills}
                onChange={(e) => setSkills(e.target.value)}
              />
            </label>
          ) : null}

          {tab === "mcp" ? (
            <label className="block text-xs text-text-muted">
              MCP servers (comma-separated names from mcp.json this agent uses)
              <input
                data-testid="editor-mcp"
                className={inputClass}
                placeholder="github, linear…"
                value={mcpServers}
                onChange={(e) => setMcpServers(e.target.value)}
              />
            </label>
          ) : null}

          {error ? (
            <div className="text-sm" style={{ color: "var(--color-role-error)" }}>
              {error}
            </div>
          ) : null}
        </div>

        <div className="flex justify-end gap-2 border-t border-border-subtle px-4 py-3">
          <button
            className="rounded-capsule border border-border-strong px-4 py-1.5 text-sm text-text-secondary hover:text-text-primary"
            onClick={onClose}
          >
            Cancel
          </button>
          <button
            data-testid="editor-save"
            className="rounded-capsule px-4 py-1.5 text-sm font-medium shadow-capsule disabled:opacity-40"
            style={{
              background:
                "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
              color: "var(--color-accent-foreground)",
            }}
            disabled={saving || (!agent && !name.trim())}
            onClick={() => void save()}
          >
            {saving ? "Saving…" : "Save"}
          </button>
        </div>
      </div>
    </div>
  );
}
