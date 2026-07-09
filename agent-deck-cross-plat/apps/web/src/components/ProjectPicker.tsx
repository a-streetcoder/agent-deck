import { useEffect, useRef, useState } from "react";
import { ChevronDown, LayoutGrid, Plus } from "lucide-react";
import { cn } from "@/lib/cn";
import { chooseDirectory, isElectron } from "@/lib/native";
import { useAppStore } from "../state/store.ts";
import { ProjectTypeIcon } from "./ProjectTypeIcon.tsx";
import { addProject, switchToProject } from "../state/wsBridge.ts";

/**
 * Toolbar project selector (native ProjectPickerPopover, SidebarViews.swift): a
 * header button showing the active project — or "All Projects" (currentProjectId
 * === null) — that opens a popover to switch project or add one. Native keeps
 * project selection in the toolbar, not the sidebar, so this lives in the app
 * header. "All Projects" is the aggregate/no-folder selection, not a persisted
 * project, so it can't be removed.
 */

function useDismiss(onDismiss: () => void) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const onMouse = (event: MouseEvent): void => {
      if (ref.current && !ref.current.contains(event.target as Node)) onDismiss();
    };
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === "Escape") {
        onDismiss();
        ref.current?.querySelector("button")?.focus();
      }
    };
    document.addEventListener("mousedown", onMouse);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onMouse);
      document.removeEventListener("keydown", onKey);
    };
  }, [onDismiss]);
  return ref;
}

export function ProjectPicker() {
  const projects = useAppStore((state) => state.projects);
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const [open, setOpen] = useState(false);
  const [adding, setAdding] = useState(false);
  const [draftPath, setDraftPath] = useState("");
  const ref = useDismiss(() => {
    setOpen(false);
    setAdding(false);
  });

  const enabled = projects.filter((project) => project.enabled !== false);
  const current = currentProjectId ? enabled.find((p) => p.id === currentProjectId) : undefined;

  const pick = async (projectId: string | null): Promise<void> => {
    setOpen(false);
    await switchToProject(projectId);
  };

  const submitPath = async (): Promise<void> => {
    const path = draftPath.trim();
    if (!path) return;
    setDraftPath("");
    setAdding(false);
    setOpen(false);
    await addProject(path);
  };

  // In the desktop app, "Add project" opens the native folder chooser; in a
  // browser it falls back to the type-a-path input inside the popover.
  const startAddProject = async (): Promise<void> => {
    if (isElectron()) {
      setOpen(false);
      const [picked] = await chooseDirectory({
        title: "Add Project",
        message: "Choose a repo or project root to add",
      });
      if (picked) await addProject(picked);
      return;
    }
    setAdding(true);
  };

  return (
    <div className="relative [-webkit-app-region:no-drag]" ref={ref}>
      <button
        data-testid="project-picker"
        className={cn(
          "flex items-center gap-2 rounded-capsule border px-2.5 py-1 text-[13px] font-medium transition-colors",
          open
            ? "border-[var(--color-selection-stroke)] bg-[var(--color-selection-fill)] text-text-primary"
            : "border-border-subtle bg-surface text-text-secondary hover:border-border-strong hover:text-text-primary",
        )}
        title="Project"
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen((v) => !v)}
      >
        {current ? (
          <ProjectTypeIcon type={current.type} size={14} />
        ) : (
          <LayoutGrid size={14} className="text-text-secondary" />
        )}
        <span className="max-w-[20ch] truncate" style={{ fontStretch: "expanded" }}>
          {current ? current.name : "All Projects"}
        </span>
        <ChevronDown size={12} className="opacity-60" />
      </button>

      {open ? (
        <div
          data-testid="project-menu"
          role="menu"
          aria-label="Project"
          className="absolute left-0 top-full z-30 mt-1.5 max-h-[70vh] w-72 overflow-y-auto rounded-xl border border-border-strong bg-surface-elevated p-1.5 shadow-elevated"
        >
          <button
            role="menuitem"
            data-testid="project-all-projects"
            className={cn(
              "flex w-full items-center gap-2.5 rounded-md px-2.5 py-1.5 text-left text-[13px]",
              currentProjectId === null
                ? "bg-[var(--color-selection-fill)] text-text-primary"
                : "text-text-secondary hover:bg-[var(--color-hover-fill)]",
            )}
            onClick={() => void pick(null)}
          >
            <LayoutGrid
              size={15}
              style={{
                color: currentProjectId === null ? "var(--color-brand-accent)" : undefined,
              }}
            />
            <span className="min-w-0 flex-1">
              <span className="block truncate" style={{ fontStretch: "expanded" }}>
                All Projects
              </span>
              <span className="block truncate text-[11px] text-text-muted">
                Sessions across every project
              </span>
            </span>
          </button>

          {enabled.map((project) => (
            <button
              key={project.id}
              role="menuitem"
              data-testid={`project-${project.name}`}
              title={project.path}
              className={cn(
                "flex w-full items-center gap-2.5 rounded-md px-2.5 py-1.5 text-left text-[13px]",
                currentProjectId === project.id
                  ? "bg-[var(--color-selection-fill)] text-text-primary"
                  : "text-text-secondary hover:bg-[var(--color-hover-fill)]",
              )}
              onClick={() => void pick(project.id)}
            >
              <ProjectTypeIcon
                type={project.type}
                size={15}
                className={
                  currentProjectId === project.id ? "text-[var(--color-brand-accent)]" : undefined
                }
              />
              <span className="truncate" style={{ fontStretch: "expanded" }}>
                {project.name}
              </span>
            </button>
          ))}

          <div className="my-1 h-px bg-border-subtle" />

          {adding ? (
            <div className="space-y-1.5 px-1 py-1">
              <input
                autoFocus
                data-testid="add-project-path"
                className="w-full rounded-md border border-border-strong bg-surface px-2 py-1.5 font-mono text-xs text-text-primary outline-none focus:border-accent"
                placeholder="/path/to/project"
                value={draftPath}
                onChange={(event) => setDraftPath(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === "Enter") void submitPath();
                  if (event.key === "Escape") setAdding(false);
                }}
              />
              <button
                data-testid="add-project-confirm"
                className="w-full rounded-capsule bg-primary px-2 py-1.5 text-xs font-medium"
                style={{ color: "var(--color-accent-foreground)" }}
                onClick={() => void submitPath()}
              >
                Add project
              </button>
            </div>
          ) : (
            <button
              role="menuitem"
              data-testid="add-project"
              className="flex w-full items-center gap-2.5 rounded-md px-2.5 py-1.5 text-left text-[13px] text-text-muted hover:bg-[var(--color-hover-fill)]"
              onClick={() => void startAddProject()}
            >
              <Plus size={15} />
              <span style={{ fontStretch: "expanded" }}>Add project</span>
            </button>
          )}
        </div>
      ) : null}
    </div>
  );
}
