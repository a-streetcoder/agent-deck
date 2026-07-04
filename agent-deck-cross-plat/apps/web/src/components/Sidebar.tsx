import { useState } from "react";
import { Folder, Plus, Send, WandSparkles } from "lucide-react";
import { cn } from "@/lib/cn";
import { useAppStore, type AppView } from "../state/store.ts";
import { addProject, switchToProject } from "../state/wsBridge.ts";
import {
  PANEL_FADE,
  PANEL_MOVE,
  SessionsCollapsedCard,
  SessionsExpandedOverlay,
} from "./SessionsPanel.tsx";

/**
 * Native sidebar structure (SidebarViews.swift): pixel-font brand title bar,
 * sectioned nav (icon + expanded-width label, accent icon when selected),
 * and the sessions pull-up panel pinned at the bottom. When the panel
 * expands, the nav recedes (scale .98, y -24, fade) exactly like
 * CodingAgentPanelLayers.
 */

const NAV: Array<{ id: AppView; label: string; icon: typeof Send }> = [
  { id: "chat", label: "Pi Agent", icon: Send },
  { id: "projects", label: "Projects", icon: Folder },
  { id: "agents", label: "Agents", icon: Send },
  { id: "skills", label: "Skills", icon: WandSparkles },
];

export function Sidebar() {
  const projects = useAppStore((state) => state.projects);
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const view = useAppStore((state) => state.view);
  const setView = useAppStore((state) => state.setView);
  const [draftPath, setDraftPath] = useState("");
  const [adding, setAdding] = useState(false);
  const [panelExpanded, setPanelExpanded] = useState(false);

  const submit = async (): Promise<void> => {
    const path = draftPath.trim();
    if (!path) return;
    await addProject(path);
    setDraftPath("");
    setAdding(false);
  };

  const rowClass = (active: boolean): string =>
    cn(
      "flex w-full items-center gap-2.5 rounded-md px-3 py-1.5 text-left text-[13px] font-medium transition-colors",
      active
        ? "bg-[var(--color-selection-fill)] text-text-primary"
        : "text-text-secondary hover:bg-[var(--color-hover-fill)]",
    );

  const sectionHeader = (label: string) => (
    <div className="px-4 pb-1 pt-3 text-[10px] font-semibold uppercase tracking-wider text-text-muted">
      {label}
    </div>
  );

  return (
    <aside
      className="flex w-[280px] shrink-0 flex-col overflow-hidden border-r border-border-subtle bg-surface-elevated"
      data-testid="sidebar"
    >
      {/* Brand title bar — the pixel wordmark's only appearance (native rule). */}
      <div className="flex items-center px-4 pb-1 pt-3">
        <span className="font-pixel text-[17px] leading-none tracking-wide text-text-primary">
          AGENT&nbsp;&nbsp;DECK
        </span>
      </div>

      {/* Panel host: everything below the logo. Two permanently-mounted
          layers — the nav (with the collapsed sessions card at its bottom)
          recedes while the expanded panel slides up and docks here. */}
      <div className="relative min-h-0 flex-1">
        {/* Nav layer */}
        <div
          className="absolute inset-0 flex flex-col"
          inert={panelExpanded}
          aria-hidden={panelExpanded}
          style={{
            transition: `${PANEL_MOVE}, ${PANEL_FADE}`,
            transformOrigin: "top",
            transform: panelExpanded ? "scale(0.98) translateY(-24px)" : "none",
            opacity: panelExpanded ? 0 : 1,
            pointerEvents: panelExpanded ? "none" : "auto",
          }}
        >
          <div className="min-h-0 flex-1 overflow-y-auto pb-2">
            {sectionHeader("Workspace")}
            <nav className="space-y-0.5 px-2">
              {NAV.map((item) => {
                const Icon = item.icon;
                const active = view === item.id;
                return (
                  <button
                    key={item.id}
                    className={rowClass(active)}
                    data-testid={`nav-${item.id}`}
                    onClick={() => setView(item.id)}
                  >
                    <Icon
                      size={15}
                      style={{ color: active ? "var(--color-brand-accent)" : undefined }}
                    />
                    <span style={{ fontStretch: "expanded" }}>{item.label}</span>
                  </button>
                );
              })}
            </nav>

            {sectionHeader("Projects")}
            <nav className="space-y-0.5 px-2">
              <button
                className={rowClass(currentProjectId === null)}
                data-testid="project-default"
                onClick={() => void switchToProject(null)}
              >
                <Folder
                  size={15}
                  style={{
                    color: currentProjectId === null ? "var(--color-brand-accent)" : undefined,
                  }}
                />
                <span style={{ fontStretch: "expanded" }}>Default</span>
              </button>
              {projects
                .filter((project) => project.enabled !== false)
                .map((project) => (
                  <button
                    key={project.id}
                    className={rowClass(currentProjectId === project.id)}
                    title={project.path}
                    data-testid={`project-${project.name}`}
                    onClick={() => void switchToProject(project.id)}
                  >
                    <Folder
                      size={15}
                      style={{
                        color:
                          currentProjectId === project.id ? "var(--color-brand-accent)" : undefined,
                      }}
                    />
                    <span className="truncate" style={{ fontStretch: "expanded" }}>
                      {project.name}
                    </span>
                  </button>
                ))}
              {adding ? (
                <div className="space-y-1.5 px-1 pt-1">
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
                    className="w-full rounded-capsule bg-primary px-2 py-1.5 text-xs font-medium"
                    style={{ color: "var(--color-accent-foreground)" }}
                    onClick={() => void submit()}
                  >
                    Add project
                  </button>
                </div>
              ) : (
                <button
                  data-testid="add-project"
                  className="flex w-full items-center gap-2.5 rounded-md px-3 py-1.5 text-left text-[13px] text-text-muted hover:bg-[var(--color-hover-fill)]"
                  onClick={() => setAdding(true)}
                >
                  <Plus size={15} />
                  <span style={{ fontStretch: "expanded" }}>Add project</span>
                </button>
              )}
            </nav>
          </div>
          <SessionsCollapsedCard onExpand={() => setPanelExpanded(true)} />
        </div>

        {/* Expanded layer — docks below the logo, full height. */}
        <SessionsExpandedOverlay
          expanded={panelExpanded}
          onCollapse={() => setPanelExpanded(false)}
        />
      </div>
    </aside>
  );
}
