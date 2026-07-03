import { useState } from "react";
import type { AgentInfo, ResourceScope } from "@agent-deck/domain";
import { useAppStore } from "../state/store.ts";

interface AgentEditorProps {
  /** Existing agent to edit, or null to create a new one. */
  agent: AgentInfo | null;
  onClose: () => void;
}

const inputClass =
  "w-full rounded-md border border-border-strong bg-surface px-2 py-1.5 text-sm text-text-primary outline-none focus:border-accent";

export function AgentEditor({ agent, onClose }: AgentEditorProps) {
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const [name, setName] = useState(agent?.name ?? "");
  const [scope, setScope] = useState<ResourceScope>(agent?.scope ?? "global");
  const [description, setDescription] = useState(agent?.description ?? "");
  const [whenToUse, setWhenToUse] = useState(agent?.whenToUse ?? "");
  const [model, setModel] = useState(agent?.model ?? "");
  const [thinking, setThinking] = useState(agent?.thinking ?? "");
  const [mode, setMode] = useState<"replace" | "append">(agent?.systemPromptMode ?? "replace");
  const [tools, setTools] = useState((agent?.tools ?? []).join(", "));
  const [skills, setSkills] = useState((agent?.skills ?? []).join(", "));
  const [body, setBody] = useState(agent?.body ?? "");
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

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
      className="rounded-lg border border-border-strong bg-surface-elevated p-4"
      data-testid="agent-editor"
    >
      <div className="mb-3 flex items-center justify-between">
        <div className="font-medium text-text-primary">
          {agent ? `Edit ${agent.name}` : "New agent"}
          {isBuiltin ? (
            <span className="ml-2 text-xs" style={{ color: "var(--color-warning)" }}>
              builtin — saved as override, file untouched
            </span>
          ) : null}
        </div>
        <button className="text-sm text-text-muted hover:text-text-primary" onClick={onClose}>
          Close
        </button>
      </div>
      <div className="grid grid-cols-2 gap-3">
        {!agent ? (
          <>
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
          </>
        ) : null}
        <label className="col-span-2 text-xs text-text-muted">
          Description
          <input
            data-testid="editor-description"
            className={inputClass}
            value={description}
            onChange={(e) => setDescription(e.target.value)}
          />
        </label>
        <label className="col-span-2 text-xs text-text-muted">
          When to use
          <input
            className={inputClass}
            value={whenToUse}
            onChange={(e) => setWhenToUse(e.target.value)}
          />
        </label>
        <label className="text-xs text-text-muted">
          Model
          <input className={inputClass} value={model} onChange={(e) => setModel(e.target.value)} />
        </label>
        <label className="text-xs text-text-muted">
          Thinking
          <select
            className={inputClass}
            value={thinking}
            onChange={(e) => setThinking(e.target.value)}
          >
            <option value="">inherit</option>
            {["off", "minimal", "low", "medium", "high", "xhigh"].map((level) => (
              <option key={level} value={level}>
                {level}
              </option>
            ))}
          </select>
        </label>
        <label className="text-xs text-text-muted">
          Tools (comma-separated)
          <input
            data-testid="editor-tools"
            className={inputClass}
            value={tools}
            onChange={(e) => setTools(e.target.value)}
          />
        </label>
        <label className="text-xs text-text-muted">
          Skills (comma-separated)
          <input
            className={inputClass}
            value={skills}
            onChange={(e) => setSkills(e.target.value)}
          />
        </label>
        <label className="text-xs text-text-muted">
          System prompt mode
          <select
            className={inputClass}
            value={mode}
            onChange={(e) => setMode(e.target.value as "replace" | "append")}
          >
            <option value="replace">replace</option>
            <option value="append">append</option>
          </select>
        </label>
        <label className="col-span-2 text-xs text-text-muted">
          System prompt (markdown body)
          <textarea
            data-testid="editor-body"
            className={`${inputClass} min-h-[140px] font-mono`}
            value={body}
            onChange={(e) => setBody(e.target.value)}
          />
        </label>
      </div>
      {error ? (
        <div className="mt-2 text-sm" style={{ color: "var(--color-role-error)" }}>
          {error}
        </div>
      ) : null}
      <div className="mt-3 flex justify-end gap-2">
        <button
          data-testid="editor-save"
          className="rounded-md bg-primary px-4 py-2 text-sm font-medium disabled:opacity-40"
          style={{ color: "var(--color-accent-foreground)" }}
          disabled={saving || (!agent && !name.trim())}
          onClick={() => void save()}
        >
          {saving ? "Saving…" : "Save"}
        </button>
      </div>
    </div>
  );
}
