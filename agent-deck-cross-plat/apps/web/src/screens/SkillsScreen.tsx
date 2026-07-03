import { useEffect, useState } from "react";
import type { SkillInfo } from "@agent-deck/domain";
import { useAppStore } from "../state/store.ts";
import { ScopeChip } from "../components/ScopeChip.tsx";

const inputClass =
  "w-full rounded-md border border-border-strong bg-surface px-2 py-1.5 text-sm text-text-primary outline-none focus:border-accent";

interface SkillDraft {
  name: string;
  scope: "global" | "project";
  description: string;
  body: string;
  isNew: boolean;
}

function SkillEditor({ draft, onClose }: { draft: SkillDraft; onClose: () => void }) {
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const [form, setForm] = useState(draft);
  const [error, setError] = useState<string | null>(null);

  const save = async (): Promise<void> => {
    try {
      const response = await fetch("/resources/skills", {
        method: "PUT",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          projectId: currentProjectId ?? undefined,
          scope: form.scope,
          name: form.name.trim(),
          edit: { description: form.description, body: form.body },
        }),
      });
      if (!response.ok) throw new Error(await response.text());
      onClose();
    } catch (err) {
      setError(String(err));
    }
  };

  return (
    <div
      className="mb-4 rounded-lg border border-border-strong bg-surface-elevated p-4"
      data-testid="skill-editor"
    >
      <div className="mb-3 flex items-center justify-between">
        <div className="font-medium text-text-primary">
          {draft.isNew ? "New skill" : `Edit ${draft.name}`}
        </div>
        <button className="text-sm text-text-muted hover:text-text-primary" onClick={onClose}>
          Close
        </button>
      </div>
      <div className="grid grid-cols-2 gap-3">
        {draft.isNew ? (
          <>
            <label className="text-xs text-text-muted">
              Name
              <input
                data-testid="skill-editor-name"
                className={inputClass}
                value={form.name}
                onChange={(e) => setForm({ ...form, name: e.target.value })}
              />
            </label>
            <label className="text-xs text-text-muted">
              Scope
              <select
                data-testid="skill-editor-scope"
                className={inputClass}
                value={form.scope}
                onChange={(e) =>
                  setForm({ ...form, scope: e.target.value as "global" | "project" })
                }
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
            data-testid="skill-editor-description"
            className={inputClass}
            value={form.description}
            onChange={(e) => setForm({ ...form, description: e.target.value })}
          />
        </label>
        <label className="col-span-2 text-xs text-text-muted">
          SKILL.md body
          <textarea
            data-testid="skill-editor-body"
            className={`${inputClass} min-h-[120px] font-mono`}
            value={form.body}
            onChange={(e) => setForm({ ...form, body: e.target.value })}
          />
        </label>
      </div>
      {error ? (
        <div className="mt-2 text-sm" style={{ color: "var(--color-role-error)" }}>
          {error}
        </div>
      ) : null}
      <div className="mt-3 flex justify-end">
        <button
          data-testid="skill-editor-save"
          className="rounded-md bg-primary px-4 py-2 text-sm font-medium disabled:opacity-40"
          style={{ color: "var(--color-accent-foreground)" }}
          disabled={!form.name.trim()}
          onClick={() => void save()}
        >
          Save
        </button>
      </div>
    </div>
  );
}

export function SkillsScreen() {
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const resourcesVersion = useAppStore((state) => state.resourcesVersion);
  const [skills, setSkills] = useState<SkillInfo[]>([]);
  const [editing, setEditing] = useState<SkillDraft | null>(null);

  useEffect(() => {
    const query = currentProjectId ? `?projectId=${encodeURIComponent(currentProjectId)}` : "";
    void fetch(`/resources/skills${query}`)
      .then((response) => response.json())
      .then((data: { skills: SkillInfo[] }) => setSkills(data.skills));
  }, [currentProjectId, resourcesVersion]);

  return (
    <div className="flex-1 overflow-y-auto px-6 py-4" data-testid="skills-screen">
      <div className="mb-4 flex justify-end">
        <button
          data-testid="new-skill"
          className="rounded-md bg-primary px-3 py-1 text-sm font-medium"
          style={{ color: "var(--color-accent-foreground)" }}
          onClick={() =>
            setEditing({ name: "", scope: "global", description: "", body: "", isNew: true })
          }
        >
          New skill
        </button>
      </div>
      {editing ? <SkillEditor draft={editing} onClose={() => setEditing(null)} /> : null}
      <div className="space-y-2">
        {skills.map((skill) => (
          <div
            key={skill.filePath}
            className="cursor-pointer rounded-lg border border-border-subtle bg-surface-elevated px-4 py-3 hover:border-border-strong"
            data-testid="skill-row"
            data-skill-name={skill.name}
            onClick={() =>
              setEditing({
                name: skill.name,
                scope: skill.scope === "project" ? "project" : "global",
                description: skill.description,
                body: skill.body,
                isNew: false,
              })
            }
          >
            <div className="flex items-center gap-2">
              <span className="font-medium text-text-primary">{skill.name}</span>
              <ScopeChip scope={skill.scope} />
            </div>
            <div className="mt-1 text-sm text-text-secondary">{skill.description}</div>
          </div>
        ))}
        {skills.length === 0 ? (
          <div className="mt-8 text-center text-text-muted">
            No skills found in ~/.pi/agent/skills or this project's .pi/skills.
          </div>
        ) : null}
      </div>
    </div>
  );
}
