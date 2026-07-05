import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Grid3x3, Pencil, Power, PowerOff, Plus, Trash2, WandSparkles, X } from "lucide-react";
import type { SkillInfo } from "@agent-deck/domain";
import { cn } from "@/lib/cn";
import { MarkdownDocument } from "@/design-system/markdown/MarkdownDocument";
import { useAppStore } from "../state/store.ts";
import { deleteSkill, setSkillDisabled, updateProject } from "../state/wsBridge.ts";
import { ScopeChip } from "../components/ScopeChip.tsx";

/**
 * Native SkillsScreen: master-detail split; rows with the wand glyph
 * (source-green when assigned), detail rendering SKILL.md as markdown, and
 * the assignment card — an "All Projects" row followed by per-project
 * checkbox rows that dim while All Projects is on
 * (SkillManagementViews.swift projectAssignmentList).
 */

const inputClass =
  "w-full rounded-lg border border-border-strong bg-surface px-2.5 py-1.5 text-sm text-text-primary outline-none focus:border-accent";

interface SkillDraft {
  name: string;
  scope: "global" | "project";
  description: string;
  body: string;
  isNew: boolean;
}

function SkillEditSheet({ draft, onClose }: { draft: SkillDraft; onClose: () => void }) {
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const [form, setForm] = useState(draft);
  const [error, setError] = useState<string | null>(null);
  const dialogRef = useRef<HTMLDivElement>(null);
  const dirty =
    form.name !== draft.name || form.description !== draft.description || form.body !== draft.body;
  const dirtyRef = useRef(dirty);
  dirtyRef.current = dirty;

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    const focusables = (): HTMLElement[] =>
      [...dialog.querySelectorAll<HTMLElement>("button, input, select, textarea")].filter(
        (el) => !el.hasAttribute("disabled"),
      );
    focusables()[1]?.focus();
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
      className="fixed inset-0 z-40 flex items-center justify-center bg-black/40 p-8"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget && !dirty) onClose();
      }}
    >
      <div
        ref={dialogRef}
        className="flex max-h-[85vh] w-[560px] flex-col rounded-2xl border border-border-strong bg-surface-elevated shadow-elevated"
        data-testid="skill-editor"
        role="dialog"
        aria-modal="true"
        aria-label={draft.isNew ? "New skill" : `Edit ${draft.name}`}
      >
        <div className="flex items-center gap-3 border-b border-border-subtle px-4 py-3">
          <span
            className="flex h-8 w-8 items-center justify-center rounded-lg"
            style={{
              background: "color-mix(in srgb, var(--color-source-project) 10%, transparent)",
              color: "var(--color-source-project)",
            }}
          >
            <WandSparkles size={15} />
          </span>
          <div
            className="flex-1 truncate text-sm font-semibold text-text-primary"
            style={{ fontStretch: "expanded" }}
          >
            {draft.isNew ? "New Skill" : `Edit ${draft.name}`}
          </div>
          <button
            className="rounded-capsule p-1.5 text-text-muted hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
            aria-label="Close"
            onClick={onClose}
          >
            <X size={15} />
          </button>
        </div>
        <div className="min-h-0 flex-1 space-y-3 overflow-y-auto p-4">
          {draft.isNew ? (
            <div className="grid grid-cols-2 gap-3">
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
            </div>
          ) : null}
          <label className="block text-xs text-text-muted">
            Description
            <input
              data-testid="skill-editor-description"
              className={inputClass}
              value={form.description}
              onChange={(e) => setForm({ ...form, description: e.target.value })}
            />
          </label>
          <label className="block text-xs text-text-muted">
            SKILL.md body
            <textarea
              data-testid="skill-editor-body"
              className={cn(inputClass, "min-h-[220px] font-mono text-[12px]")}
              value={form.body}
              onChange={(e) => setForm({ ...form, body: e.target.value })}
            />
          </label>
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
            data-testid="skill-editor-save"
            className="rounded-capsule px-4 py-1.5 text-sm font-medium shadow-capsule disabled:opacity-40"
            style={{
              background:
                "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
              color: "var(--color-accent-foreground)",
            }}
            disabled={!form.name.trim()}
            onClick={() => void save()}
          >
            Save
          </button>
        </div>
      </div>
    </div>
  );
}

function AssignmentCard({ skill }: { skill: SkillInfo }) {
  const projects = useAppStore((state) => state.projects);
  const [defaultSkills, setDefaultSkills] = useState<string[]>([]);

  const refreshSettings = useCallback(async (): Promise<void> => {
    try {
      const response = await fetch("/settings");
      if (!response.ok) return;
      const { settings } = (await response.json()) as { settings: { defaultSkills: string[] } };
      setDefaultSkills(settings.defaultSkills);
    } catch {
      // Transient — next refresh wins.
    }
  }, []);

  // Refetch when the selected skill changes so another tab's edits show up.
  useEffect(() => {
    void refreshSettings();
  }, [refreshSettings, skill.name]);

  const allProjects = defaultSkills.includes(skill.name);

  const toggleAllProjects = async (enabled: boolean): Promise<void> => {
    const next = new Set(defaultSkills);
    if (enabled) next.add(skill.name);
    else next.delete(skill.name);
    setDefaultSkills([...next]); // optimistic — checkbox must flip immediately
    // Atomic membership op: the server computes against CURRENT state, so
    // concurrent edits to other skills can't be clobbered.
    await fetch("/settings", {
      method: "PATCH",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ setDefaultSkill: { name: skill.name, enabled } }),
    }).catch(() => {});
    await refreshSettings();
  };

  return (
    <div className="rounded-xl border border-border-subtle bg-surface-elevated px-4 py-3">
      <div className="pb-1 text-[10px] font-semibold uppercase tracking-wider text-text-muted">
        Project assignment
      </div>
      <p className="pb-2 text-xs text-text-muted">
        Assigned skills are passed to new sessions as explicit --skill paths (no ambient discovery).
        Changes apply to the next session.
      </p>
      {skill.disabled ? (
        <p className="pb-2 text-xs" style={{ color: "var(--color-warning)" }}>
          This skill is disabled — enable it to assign it to projects.
        </p>
      ) : null}
      <label className="flex items-center gap-2.5 rounded-lg px-2 py-1.5 hover:bg-[var(--color-hover-fill)]">
        <input
          type="checkbox"
          data-testid={`assign-skill-all-${skill.name}`}
          checked={allProjects}
          disabled={skill.disabled}
          onChange={(event) => void toggleAllProjects(event.target.checked)}
        />
        <Grid3x3 size={14} className="text-text-muted" />
        <span className="text-sm text-text-primary">All Projects</span>
        <span className="text-xs text-text-muted">enable this skill for every project</span>
      </label>
      <div className="my-1.5 border-t border-border-subtle" />
      <div
        className={cn(
          "space-y-0.5",
          (allProjects || skill.disabled) && "pointer-events-none opacity-40",
        )}
      >
        {projects.map((project) => {
          const assigned = (project.assignedSkills ?? []).includes(skill.name);
          return (
            <label
              key={project.id}
              className="flex items-center gap-2.5 rounded-lg px-2 py-1.5 hover:bg-[var(--color-hover-fill)]"
            >
              <input
                type="checkbox"
                data-testid={`assign-skill-${skill.name}-${project.name}`}
                checked={assigned}
                disabled={allProjects || skill.disabled}
                onChange={(event) => {
                  const next = new Set(project.assignedSkills ?? []);
                  if (event.target.checked) next.add(skill.name);
                  else next.delete(skill.name);
                  void updateProject(project.id, { assignedSkills: [...next] });
                }}
              />
              <span className="text-sm text-text-primary">{project.name}</span>
              <span className="truncate font-mono text-xs text-text-muted">{project.path}</span>
            </label>
          );
        })}
        {projects.length === 0 ? (
          <div className="px-2 py-1.5 text-xs text-text-muted">No projects registered.</div>
        ) : null}
      </div>
    </div>
  );
}

export function SkillsScreen() {
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const resourcesVersion = useAppStore((state) => state.resourcesVersion);
  const projects = useAppStore((state) => state.projects);
  const [skills, setSkills] = useState<SkillInfo[]>([]);
  const [search, setSearch] = useState("");
  const [selectedKey, setSelectedKey] = useState<string | null>(null);
  const [editing, setEditing] = useState<SkillDraft | null>(null);

  useEffect(() => {
    const query = currentProjectId ? `?projectId=${encodeURIComponent(currentProjectId)}` : "";
    let cancelled = false;
    void fetch(`/resources/skills${query}`)
      .then((response) => response.json())
      .then((data: { skills: SkillInfo[] }) => {
        if (!cancelled) setSkills(data.skills);
      });
    return () => {
      cancelled = true;
    };
  }, [currentProjectId, resourcesVersion]);

  const assignedNames = useMemo(() => {
    const names = new Set<string>();
    for (const project of projects) {
      for (const name of project.assignedSkills ?? []) names.add(name);
    }
    return names;
  }, [projects]);

  const visible = useMemo(() => {
    const query = search.trim().toLowerCase();
    return skills.filter(
      (skill) =>
        query === "" ||
        skill.name.toLowerCase().includes(query) ||
        skill.description.toLowerCase().includes(query),
    );
  }, [skills, search]);

  const selected = visible.find((s) => s.filePath === selectedKey) ?? visible[0] ?? null;

  const editDraft = (skill: SkillInfo): SkillDraft => ({
    name: skill.name,
    scope: skill.scope === "project" ? "project" : "global",
    description: skill.description,
    body: skill.body,
    isNew: false,
  });

  return (
    <div className="flex min-h-0 flex-1" data-testid="skills-screen">
      {/* List pane */}
      <div className="flex w-[42%] min-w-[320px] flex-col border-r border-border-subtle">
        <div className="flex items-center gap-2 px-3 pb-2 pt-3">
          <input
            data-testid="skill-search"
            className="min-w-0 flex-1 rounded-lg border border-border-strong bg-surface px-2.5 py-1.5 text-sm text-text-primary outline-none focus:border-accent"
            placeholder="Search skills"
            value={search}
            onChange={(event) => setSearch(event.target.value)}
          />
          <button
            data-testid="new-skill"
            className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full shadow-capsule"
            style={{
              background:
                "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
              color: "var(--color-accent-foreground)",
            }}
            title="New skill"
            onClick={() =>
              setEditing({ name: "", scope: "global", description: "", body: "", isNew: true })
            }
          >
            <Plus size={15} />
          </button>
        </div>
        <div
          className="min-h-0 flex-1 space-y-1 overflow-y-auto px-3 pb-4"
          role="listbox"
          aria-label="Skills"
        >
          {visible.map((skill) => {
            const isSelected = selected?.filePath === skill.filePath;
            const isAssigned = assignedNames.has(skill.name);
            return (
              <div
                key={skill.filePath}
                className={cn(
                  "group flex cursor-pointer items-center gap-3 rounded-xl border px-3 py-2 transition-colors",
                  "focus-visible:outline focus-visible:outline-2 focus-visible:outline-[var(--color-brand-accent)]",
                  isSelected
                    ? "border-[var(--color-selection-stroke)] bg-[var(--color-selection-fill)]"
                    : "border-transparent hover:bg-[var(--color-hover-fill)]",
                  skill.disabled && "opacity-60 saturate-50",
                )}
                data-testid="skill-row"
                data-skill-name={skill.name}
                role="option"
                aria-selected={isSelected}
                tabIndex={0}
                onClick={() => setSelectedKey(skill.filePath)}
                onKeyDown={(event) => {
                  if (event.key === "Enter" || event.key === " ") {
                    event.preventDefault();
                    setSelectedKey(skill.filePath);
                  }
                }}
              >
                <WandSparkles
                  size={17}
                  className="shrink-0"
                  style={{
                    color: isAssigned ? "var(--color-source-project)" : "var(--color-text-muted)",
                  }}
                />
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-2">
                    <span
                      className="truncate text-sm font-semibold text-text-primary"
                      style={{ fontStretch: "expanded" }}
                    >
                      {skill.name}
                    </span>
                    <ScopeChip scope={skill.scope} />
                    {skill.disabled ? (
                      <span
                        className="rounded-capsule border px-1.5 text-[10px]"
                        style={{
                          color: "var(--color-text-muted)",
                          borderColor: "var(--color-border-strong)",
                        }}
                        data-testid="skill-disabled-badge"
                      >
                        disabled
                      </span>
                    ) : null}
                  </div>
                  <div className="truncate text-xs text-text-secondary">{skill.description}</div>
                </div>
                <button
                  className="rounded-capsule border border-border-strong px-2.5 py-1 text-xs text-text-secondary opacity-0 transition-opacity hover:text-text-primary focus-visible:opacity-100 group-hover:opacity-100"
                  onClick={(event) => {
                    event.stopPropagation();
                    setSelectedKey(skill.filePath);
                    setEditing(editDraft(skill));
                  }}
                >
                  Edit
                </button>
              </div>
            );
          })}
          {visible.length === 0 ? (
            <div className="mt-8 text-center text-sm text-text-muted">
              No skills found in ~/.pi/agent/skills or this project's .pi/skills.
            </div>
          ) : null}
        </div>
      </div>

      {/* Detail pane */}
      {selected ? (
        <div className="min-h-0 flex-1 overflow-y-auto px-6 py-5" data-testid="skill-detail">
          <div className="flex items-start gap-3">
            <span
              className="mt-0.5 flex h-10 w-10 shrink-0 items-center justify-center rounded-full"
              style={{
                background: "color-mix(in srgb, var(--color-source-project) 10%, transparent)",
                border:
                  "1px solid color-mix(in srgb, var(--color-source-project) 18%, transparent)",
                color: "var(--color-source-project)",
              }}
            >
              <WandSparkles size={17} />
            </span>
            <div className="min-w-0 flex-1">
              <div className="flex items-center gap-2">
                <h2
                  className="truncate text-xl font-bold text-text-primary"
                  style={{ fontStretch: "expanded" }}
                >
                  {selected.name}
                </h2>
                <ScopeChip scope={selected.scope} />
              </div>
              <p className="mt-0.5 text-sm text-text-secondary">{selected.description}</p>
            </div>
            <div className="flex shrink-0 items-center gap-2">
              <button
                data-testid="skill-disable"
                className="flex items-center gap-1.5 rounded-capsule border border-border-strong px-2.5 py-1 text-xs text-text-secondary hover:text-text-primary"
                onClick={() => void setSkillDisabled(selected.name, !selected.disabled)}
              >
                {selected.disabled ? <Power size={12} /> : <PowerOff size={12} />}
                {selected.disabled ? "Enable" : "Disable"}
              </button>
              <button
                data-testid="skill-edit"
                className="flex items-center gap-1.5 rounded-capsule px-3 py-1 text-xs font-medium shadow-capsule"
                style={{
                  background:
                    "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
                  color: "var(--color-accent-foreground)",
                }}
                onClick={() => setEditing(editDraft(selected))}
              >
                <Pencil size={12} />
                Edit SKILL.md
              </button>
              <button
                data-testid="skill-delete"
                className="rounded-capsule border border-border-strong p-1.5 text-text-muted hover:text-[var(--color-role-error)]"
                title="Delete skill"
                onClick={() => {
                  if (confirm(`Delete skill "${selected.name}"? This removes its SKILL.md.`)) {
                    void deleteSkill(selected.scope, selected.name);
                  }
                }}
              >
                <Trash2 size={13} />
              </button>
            </div>
          </div>

          <div className="mt-5 space-y-4">
            <AssignmentCard skill={selected} />
            <div className="rounded-xl border border-border-subtle bg-surface-elevated px-4 py-3">
              <div className="pb-2 text-[10px] font-semibold uppercase tracking-wider text-text-muted">
                SKILL.md
              </div>
              <MarkdownDocument source={selected.body || "_(empty)_"} />
            </div>
            <div className="truncate text-xs text-text-muted" title={selected.filePath}>
              {selected.filePath}
            </div>
          </div>
        </div>
      ) : (
        <div className="flex flex-1 items-center justify-center text-sm text-text-muted">
          Select a skill.
        </div>
      )}

      {editing ? <SkillEditSheet draft={editing} onClose={() => setEditing(null)} /> : null}
    </div>
  );
}
