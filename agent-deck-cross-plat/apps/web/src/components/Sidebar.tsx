import { useState } from "react";
import { useAppStore } from "../state/store.ts";
import { addProject, switchToProject } from "../state/wsBridge.ts";

export function Sidebar() {
  const projects = useAppStore((state) => state.projects);
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const [draftPath, setDraftPath] = useState("");
  const [adding, setAdding] = useState(false);

  const submit = async (): Promise<void> => {
    const path = draftPath.trim();
    if (!path) return;
    await addProject(path);
    setDraftPath("");
    setAdding(false);
  };

  const itemClass = (active: boolean): string =>
    `w-full truncate rounded-md px-3 py-2 text-left text-sm transition-colors ${
      active
        ? "bg-[var(--color-selection-fill)] text-text-primary"
        : "text-text-secondary hover:bg-[var(--color-hover-fill)]"
    }`;

  return (
    <aside
      className="flex w-60 shrink-0 flex-col border-r border-border-subtle bg-surface-elevated"
      data-testid="sidebar"
    >
      <div className="px-4 pb-2 pt-4 text-xs font-semibold uppercase tracking-wider text-text-muted">
        Projects
      </div>
      <nav className="flex-1 space-y-1 overflow-y-auto px-2">
        <button
          className={itemClass(currentProjectId === null)}
          data-testid="project-default"
          onClick={() => void switchToProject(null)}
        >
          Default
        </button>
        {projects.map((project) => (
          <button
            key={project.id}
            className={itemClass(currentProjectId === project.id)}
            title={project.path}
            data-testid={`project-${project.name}`}
            onClick={() => void switchToProject(project.id)}
          >
            {project.name}
          </button>
        ))}
      </nav>
      <div className="border-t border-border-subtle p-2">
        {adding ? (
          <div className="space-y-2">
            <input
              autoFocus
              data-testid="add-project-path"
              className="w-full rounded-md border border-border-strong bg-surface px-2 py-1.5 font-mono text-xs text-text-primary outline-none focus:border-accent"
              placeholder="/path/to/project"
              value={draftPath}
              onChange={(event) => setDraftPath(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter") void submit();
                if (event.key === "Escape") setAdding(false);
              }}
            />
            <button
              data-testid="add-project-confirm"
              className="w-full rounded-md bg-primary px-2 py-1.5 text-sm font-medium"
              style={{ color: "var(--color-accent-foreground)" }}
              onClick={() => void submit()}
            >
              Add project
            </button>
          </div>
        ) : (
          <button
            data-testid="add-project"
            className="w-full rounded-md px-3 py-2 text-left text-sm text-text-muted hover:bg-[var(--color-hover-fill)]"
            onClick={() => setAdding(true)}
          >
            + Add project
          </button>
        )}
      </div>
    </aside>
  );
}
