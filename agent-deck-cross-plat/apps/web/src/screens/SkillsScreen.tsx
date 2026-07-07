import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  Check,
  FolderInput,
  Grid3x3,
  Pencil,
  Power,
  PowerOff,
  Plus,
  Tag,
  Trash2,
  WandSparkles,
  X,
} from "lucide-react";
import type { SkillInfo } from "@agent-deck/domain";
import { cn } from "@/lib/cn";
import { MarkdownDocument } from "@/design-system/markdown/MarkdownDocument";
import { useAppStore } from "../state/store.ts";
import { deleteSkill, renameSkill, setSkillDisabled, updateProject } from "../state/wsBridge.ts";
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

/**
 * Mirrors pi's skill-name validity (skills.js validateName): ≤64 chars,
 * lowercase a-z / 0-9 / hyphens only, no leading/trailing or doubled hyphens.
 * The `/skill:<name>` invocation is only shown for a valid name, so the command
 * we display always actually resolves in pi (its parser stops at the first
 * space and it warns on — but still loads — otherwise-invalid names).
 */
function isValidSkillCommandName(name: string): boolean {
  return (
    name.length <= 64 &&
    /^[a-z0-9-]+$/.test(name) &&
    !name.startsWith("-") &&
    !name.endsWith("-") &&
    !name.includes("--")
  );
}

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
  // After a rename the skill's filePath changes (its directory moves), so a
  // filePath-keyed selection would fall back to visible[0] and show the wrong
  // skill. Remember the renamed skill by its EXACT new filePath (deterministic:
  // renameSkillDir moves the dir to <catalog>/<newName>) and re-select it once
  // the refetch lands. Keying on the precise path — not (name, scope) — avoids
  // re-pointing to an unrelated same-name skill.
  const [pendingSelectPath, setPendingSelectPath] = useState<string | null>(null);
  const [editing, setEditing] = useState<SkillDraft | null>(null);
  // Inline rename of the selected skill; value === null when not renaming.
  const [renameValue, setRenameValue] = useState<string | null>(null);
  // Multi-select for bulk actions (native 7.5), by filePath.
  const [checked, setChecked] = useState<Set<string>>(new Set());
  // Local-import path input (native SkillImportSheet); null when not importing.
  const [importPath, setImportPath] = useState<string | null>(null);
  const setGlobalError = useAppStore((state) => state.setError);

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

  // Intersect with the live skills so a stale filePath (deleted skill) drops out.
  const checkedSkills = skills.filter((s) => checked.has(s.filePath));
  const toggleCheck = (filePath: string): void =>
    setChecked((prev) => {
      const next = new Set(prev);
      if (next.has(filePath)) next.delete(filePath);
      else next.add(filePath);
      return next;
    });

  // Prune the selection to live skills after any reload: successfully deleted
  // skills drop out on their own, a FAILED delete stays checked (retry set
  // preserved), and no ghost filePaths accumulate.
  useEffect(() => {
    setChecked((prev) => {
      const live = new Set(skills.map((s) => s.filePath));
      const next = new Set([...prev].filter((fp) => live.has(fp)));
      return next.size === prev.size ? prev : next;
    });
  }, [skills]);

  const bulkDelete = async (): Promise<void> => {
    // deleteSkill reloads on success; the prune effect then clears the deleted
    // ones from the selection (no blanket clear, so failures stay selected).
    await Promise.all(checkedSkills.map((s) => deleteSkill(s.scope, s.name)));
  };

  const doImport = async (): Promise<void> => {
    const sourcePath = (importPath ?? "").trim();
    if (!sourcePath) return;
    try {
      const res = await fetch("/resources/skills/import", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ scope: "global", sourcePath }),
      });
      if (!res.ok) {
        const { error } = (await res.json().catch(() => ({}))) as { error?: string };
        throw new Error(error ?? "Couldn't import the skill.");
      }
      setImportPath(null); // the new skill arrives via the resources_changed refetch
    } catch (err) {
      setGlobalError(String(err));
    }
  };

  // A manual selection (row click) supersedes any pending post-rename re-select,
  // so a delayed refetch can't yank the user off a skill they just clicked.
  const selectSkill = useCallback((filePath: string): void => {
    setPendingSelectPath(null);
    setSelectedKey(filePath);
  }, []);

  // Once the post-rename refetch lands the renamed skill (by its exact new path),
  // re-point the selection to it so the detail stays on it (native master-detail
  // keeps the renamed row selected).
  useEffect(() => {
    if (!pendingSelectPath) return;
    if (skills.some((s) => s.filePath === pendingSelectPath)) {
      setSelectedKey(pendingSelectPath);
      setPendingSelectPath(null);
    }
  }, [skills, pendingSelectPath]);

  // A project switch abandons any pending re-select — it belonged to the old
  // project's catalog.
  useEffect(() => {
    setPendingSelectPath(null);
  }, [currentProjectId]);

  const selected = visible.find((s) => s.filePath === selectedKey) ?? visible[0] ?? null;

  // Close an open rename if the selected skill changes, so a pending value can't
  // apply to a different skill.
  useEffect(() => {
    setRenameValue(null);
  }, [selected?.filePath]);

  const editDraft = (skill: SkillInfo): SkillDraft => ({
    name: skill.name,
    scope: skill.scope === "project" ? "project" : "global",
    description: skill.description,
    body: skill.body,
    isNew: false,
  });

  const submitRename = async (skill: SkillInfo): Promise<void> => {
    const newName = (renameValue ?? "").trim();
    if (!newName || newName === skill.name) {
      setRenameValue(null);
      return;
    }
    if (await renameSkill(skill.scope, skill.name, newName)) {
      setRenameValue(null);
      // Keep the detail on the renamed skill once the refetch replaces its path.
      // renameSkillDir moves the dir to <catalog>/<newName>, keeping the file's
      // basename, so the new path is the old baseDir's parent + newName + file.
      const sep = skill.baseDir.includes("\\") ? "\\" : "/";
      const parent = skill.baseDir.slice(0, skill.baseDir.lastIndexOf(sep));
      const fileName = skill.filePath.slice(skill.filePath.lastIndexOf(sep) + 1);
      setPendingSelectPath(`${parent}${sep}${newName}${sep}${fileName}`);
    }
  };

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
          <button
            data-testid="skill-import"
            className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full border border-border-strong text-text-secondary hover:text-text-primary"
            title="Import a local .md file as a skill"
            onClick={() => setImportPath((v) => (v === null ? "" : null))}
          >
            <FolderInput size={15} />
          </button>
        </div>
        {importPath !== null ? (
          <div className="mx-3 mb-2 flex gap-2">
            <input
              autoFocus
              data-testid="skill-import-path"
              className="min-w-0 flex-1 rounded-lg border border-border-strong bg-surface px-2.5 py-1.5 font-mono text-xs text-text-primary outline-none focus:border-accent"
              placeholder="/path/to/skill.md"
              value={importPath}
              onChange={(event) => setImportPath(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter") void doImport();
                if (event.key === "Escape") setImportPath(null);
              }}
            />
            <button
              data-testid="skill-import-confirm"
              className="rounded-capsule border border-border-strong px-2.5 text-xs text-text-secondary hover:text-text-primary disabled:opacity-40"
              disabled={!importPath.trim()}
              onClick={() => void doImport()}
            >
              Import
            </button>
          </div>
        ) : null}
        {checkedSkills.length > 0 ? (
          <div
            className="mx-3 mb-2 flex items-center gap-2 rounded-lg border border-border-strong bg-surface-elevated px-2.5 py-1.5 text-xs"
            data-testid="skills-bulk-bar"
          >
            <span className="flex-1 text-text-secondary">{checkedSkills.length} selected</span>
            <button
              data-testid="skills-bulk-clear"
              className="rounded px-1.5 py-0.5 text-text-muted hover:text-text-primary"
              onClick={() => setChecked(new Set())}
            >
              Clear
            </button>
            <button
              data-testid="skills-bulk-delete"
              className="flex items-center gap-1 rounded-capsule border border-border-strong px-2 py-0.5 text-text-muted hover:text-[var(--color-role-error)]"
              onClick={() => void bulkDelete()}
            >
              <Trash2 size={12} /> Delete
            </button>
          </div>
        ) : null}
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
                onClick={() => selectSkill(skill.filePath)}
                onKeyDown={(event) => {
                  // Ignore keys bubbled from the checkbox (its own Space toggles
                  // it) — only the row's own Enter/Space opens the detail.
                  if (event.target !== event.currentTarget) return;
                  if (event.key === "Enter" || event.key === " ") {
                    event.preventDefault();
                    selectSkill(skill.filePath);
                  }
                }}
              >
                <input
                  type="checkbox"
                  data-testid={`skill-check-${skill.name}`}
                  aria-label={`Select ${skill.name}`}
                  className="shrink-0 accent-[var(--color-brand-accent)]"
                  checked={checked.has(skill.filePath)}
                  onClick={(event) => event.stopPropagation()}
                  onChange={() => toggleCheck(skill.filePath)}
                />
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
                    selectSkill(skill.filePath);
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
                {renameValue !== null ? (
                  <>
                    <input
                      autoFocus
                      data-testid="skill-rename-input"
                      className="min-w-0 flex-1 rounded-lg border border-border-strong bg-surface px-2 py-1 text-lg font-bold text-text-primary outline-none focus:border-accent"
                      value={renameValue}
                      onChange={(e) => setRenameValue(e.target.value)}
                      onKeyDown={(e) => {
                        if (e.key === "Enter") void submitRename(selected);
                        if (e.key === "Escape") setRenameValue(null);
                      }}
                    />
                    <button
                      data-testid="skill-rename-confirm"
                      className="rounded p-1 text-text-muted hover:text-[var(--color-brand-accent)]"
                      title="Rename"
                      onClick={() => void submitRename(selected)}
                    >
                      <Check size={16} />
                    </button>
                    <button
                      data-testid="skill-rename-cancel"
                      className="rounded p-1 text-text-muted hover:text-text-primary"
                      title="Cancel"
                      onClick={() => setRenameValue(null)}
                    >
                      <X size={16} />
                    </button>
                  </>
                ) : (
                  <h2
                    className="truncate text-xl font-bold text-text-primary"
                    style={{ fontStretch: "expanded" }}
                  >
                    {selected.name}
                  </h2>
                )}
                <ScopeChip scope={selected.scope} />
                {selected.disableModelInvocation ? (
                  <span
                    data-testid="skill-manual-only-badge"
                    className="rounded-capsule border border-border-subtle px-1.5 text-[10px] text-text-muted"
                    title="disable-model-invocation is set: the model won't auto-invoke this skill. It's only used when invoked explicitly (e.g. via the composer's / menu)."
                  >
                    manual only
                  </span>
                ) : null}
              </div>
              <p className="mt-0.5 text-sm text-text-secondary">{selected.description}</p>
              {/* How pi invokes this skill explicitly (agent-session _expandSkillCommand
                  matches `/skill:<name>`, where name is pi's resolved skill name —
                  frontmatter `name` or the directory basename — which is exactly
                  SkillInfo.name). Distinct from prompts' `/name` form. Only shown
                  for a pi-valid name (isValidSkillCommandName) so the displayed
                  command always resolves; pi warns on — but still loads — names
                  it considers invalid, which wouldn't invoke as typed. */}
              {isValidSkillCommandName(selected.name) ? (
                <code
                  data-testid="skill-invocation"
                  className="mt-1 inline-block font-mono text-xs text-text-muted"
                >
                  /skill:{selected.name}
                </code>
              ) : null}
            </div>
            <div className="flex shrink-0 items-center gap-2">
              <button
                data-testid="skill-rename"
                className="flex items-center gap-1.5 rounded-capsule border border-border-strong px-2.5 py-1 text-xs text-text-secondary hover:text-text-primary"
                onClick={() => setRenameValue(selected.name)}
              >
                <Tag size={12} />
                Rename
              </button>
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
