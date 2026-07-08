import { useCallback, useEffect, useState } from "react";
import { EyeOff, Github, Plus, RefreshCw, Search, Send, WandSparkles, X } from "lucide-react";
import type { DiscoveredProject, ProjectMeta } from "@agent-deck/domain";
import { cn } from "@/lib/cn";
import { chooseDirectory, isElectron } from "@/lib/native";
import { ProjectTypeIcon } from "../components/ProjectTypeIcon.tsx";
import { useAppStore } from "../state/store.ts";
import { addProject, refreshProjects, updateProject } from "../state/wsBridge.ts";

/**
 * Native ProjectsScreen (ProjectViews.swift): a scrollable page with one
 * "Library" card — segmented All/Enabled/Disabled filter, helper caption,
 * then radius-14 project rows: icon, expanded-width name, "Active" accent
 * tag, mono middle-truncated path, Enabled switch, recap glyph buttons,
 * and a destructive hide button. Disabled rows dim.
 */

type Filter = "all" | "enabled" | "disabled";

function isEnabled(project: ProjectMeta): boolean {
  return project.enabled !== false;
}

function Switch({
  checked,
  onChange,
  testid,
  disabled,
}: {
  checked: boolean;
  onChange: (checked: boolean) => void;
  testid: string;
  disabled?: boolean;
}) {
  return (
    <button
      role="switch"
      aria-checked={checked}
      data-testid={testid}
      disabled={disabled}
      className="relative h-5 w-9 rounded-capsule transition-colors disabled:opacity-40"
      style={{
        background: checked ? "var(--color-brand-accent)" : "var(--color-surface-subtle)",
        border: "1px solid var(--color-border-strong)",
      }}
      onClick={() => onChange(!checked)}
    >
      <span
        className="absolute top-0.5 h-3.5 w-3.5 rounded-full bg-white transition-all"
        style={{ left: checked ? "calc(100% - 18px)" : "2px" }}
      />
    </button>
  );
}

function RecapButton({
  icon: Icon,
  title,
  count,
}: {
  icon: typeof Send;
  title: string;
  count: number;
}) {
  return (
    <span
      className={cn(
        "flex items-center gap-1 rounded-capsule border border-border-subtle px-2 py-0.5 text-[11px]",
        count > 0 ? "text-text-secondary" : "text-text-muted opacity-50",
      )}
      title={`${title}: ${count}`}
    >
      <Icon size={11} />
      {count}
    </span>
  );
}

function DiscoveryPanel() {
  const setError = useAppStore((state) => state.setError);
  const [roots, setRoots] = useState<string[]>([]);
  const [discovered, setDiscovered] = useState<DiscoveredProject[]>([]);
  const [rootDraft, setRootDraft] = useState("");
  const [scanning, setScanning] = useState(false);

  const scan = useCallback(async (): Promise<void> => {
    setScanning(true);
    try {
      const response = await fetch("/projects/discovery");
      if (!response.ok) throw new Error(await response.text());
      const data = (await response.json()) as { roots: string[]; discovered: DiscoveredProject[] };
      setRoots(data.roots);
      setDiscovered(data.discovered);
    } catch (err) {
      setError(String(err));
    } finally {
      setScanning(false);
    }
  }, [setError]);

  useEffect(() => {
    void scan();
  }, [scan]);

  const postRoot = async (root: string): Promise<boolean> => {
    const response = await fetch("/projects/discovery/roots", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ root }),
    });
    if (!response.ok) {
      setError(await response.text());
      return false;
    }
    return true;
  };

  const addRoot = async (): Promise<void> => {
    const root = rootDraft.trim();
    if (!root) return;
    if (await postRoot(root)) {
      setRootDraft("");
      await scan();
    }
  };

  // Desktop: pick one or more parent folders with the native chooser.
  const browseRoots = async (): Promise<void> => {
    const picked = await chooseDirectory({
      title: "Choose Projects Folder",
      message: "Choose one or more parent folders that contain your projects",
      multiple: true,
    });
    let any = false;
    for (const root of picked) any = (await postRoot(root)) || any;
    if (any) await scan();
  };

  const removeRoot = async (root: string): Promise<void> => {
    await fetch("/projects/discovery/roots", {
      method: "DELETE",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ root }),
    }).catch(() => {});
    await scan();
  };

  const unregistered = discovered.filter((d) => !d.registered);

  return (
    <div className="mb-4 rounded-2xl border border-border-subtle bg-surface-elevated p-4">
      <div className="flex items-center justify-between pb-1">
        <div className="flex items-center gap-2">
          <Search size={15} className="text-text-secondary" />
          <h3
            className="text-sm font-semibold text-text-primary"
            style={{ fontStretch: "expanded" }}
          >
            Discover
          </h3>
        </div>
        <button
          data-testid="discovery-rescan"
          className="flex items-center gap-1.5 rounded-capsule border border-border-strong px-2.5 py-0.5 text-xs text-text-secondary hover:text-text-primary disabled:opacity-40"
          disabled={scanning}
          onClick={() => void scan()}
        >
          <RefreshCw size={11} className={scanning ? "animate-spin" : undefined} />
          Rescan
        </button>
      </div>
      <p className="pb-2 text-xs text-text-muted">
        Scan folders for git repos and known project types, then add them with one click.
      </p>

      <div className="flex gap-2 pb-2">
        {isElectron() ? (
          <button
            data-testid="discovery-root-browse"
            className="rounded-capsule border border-border-strong px-3 py-1.5 text-xs text-text-secondary hover:text-text-primary"
            onClick={() => void browseRoots()}
          >
            Choose folder…
          </button>
        ) : (
          <>
            <input
              data-testid="discovery-root-input"
              className="min-w-0 flex-1 rounded-lg border border-border-strong bg-surface px-2.5 py-1.5 font-mono text-xs text-text-primary outline-none focus:border-accent"
              placeholder="/path/to/dev/folder"
              value={rootDraft}
              onChange={(e) => setRootDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") void addRoot();
              }}
            />
            <button
              data-testid="discovery-root-add"
              className="rounded-capsule border border-border-strong px-3 py-1.5 text-xs text-text-secondary hover:text-text-primary disabled:opacity-40"
              disabled={!rootDraft.trim()}
              onClick={() => void addRoot()}
            >
              Add root
            </button>
          </>
        )}
      </div>

      {roots.length > 0 ? (
        <div className="flex flex-wrap gap-1.5 pb-2">
          {roots.map((root) => (
            <span
              key={root}
              data-testid="discovery-root-chip"
              className="flex items-center gap-1 rounded-capsule border border-border-subtle bg-surface px-2 py-0.5 font-mono text-[11px] text-text-secondary"
            >
              {root}
              <button
                className="text-text-muted hover:text-[var(--color-role-error)]"
                title="Remove root"
                onClick={() => void removeRoot(root)}
              >
                <X size={11} />
              </button>
            </span>
          ))}
        </div>
      ) : null}

      <div className="space-y-1" data-testid="discovery-results">
        {unregistered.map((candidate) => (
          <div
            key={candidate.path}
            className="flex items-center gap-3 rounded-lg border border-border-subtle bg-surface px-3 py-1.5"
            data-testid="discovery-candidate"
            data-candidate-name={candidate.name}
          >
            <ProjectTypeIcon
              type={candidate.type}
              size={15}
              className="shrink-0 text-text-secondary"
            />
            <span
              className="text-sm font-medium text-text-primary"
              style={{ fontStretch: "expanded" }}
            >
              {candidate.name}
            </span>
            <span className="rounded-capsule border border-border-subtle px-1.5 text-[10px] text-text-muted">
              {candidate.type}
            </span>
            <span className="min-w-0 flex-1 truncate font-mono text-[11px] text-text-muted">
              {candidate.path}
            </span>
            <button
              data-testid={`discovery-add-${candidate.name}`}
              className="rounded-capsule px-2.5 py-0.5 text-xs font-medium shadow-capsule"
              style={{
                background:
                  "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
                color: "var(--color-accent-foreground)",
              }}
              onClick={() => void addProject(candidate.path).then(() => void scan())}
            >
              Add
            </button>
          </div>
        ))}
        {roots.length > 0 && unregistered.length === 0 ? (
          <div className="py-2 text-center text-xs text-text-muted">
            No new projects found under the configured roots.
          </div>
        ) : null}
        {roots.length === 0 ? (
          <div className="py-2 text-center text-xs text-text-muted">
            Add a root folder above to discover projects.
          </div>
        ) : null}
      </div>
    </div>
  );
}

export function ProjectsScreen() {
  const projects = useAppStore((state) => state.projects);
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const [filter, setFilter] = useState<Filter>("enabled");
  const [draftPath, setDraftPath] = useState("");
  const [adding, setAdding] = useState(false);

  const visible = projects.filter((project) =>
    filter === "all" ? true : filter === "enabled" ? isEnabled(project) : !isEnabled(project),
  );

  const hide = async (project: ProjectMeta): Promise<void> => {
    await fetch(`/projects/${encodeURIComponent(project.id)}`, { method: "DELETE" }).catch(
      () => {},
    );
    await refreshProjects();
  };

  // Desktop uses the native folder chooser; browser toggles the path input.
  const startAdd = async (): Promise<void> => {
    if (isElectron()) {
      const [picked] = await chooseDirectory({
        title: "Add Project",
        message: "Choose a repo or project root to add",
      });
      if (picked) await addProject(picked);
      return;
    }
    setAdding((v) => !v);
  };

  return (
    <div className="min-h-0 flex-1 overflow-y-auto px-6 py-5" data-testid="projects-screen">
      <DiscoveryPanel />
      <div className="rounded-2xl border border-border-subtle bg-surface-elevated p-4">
        <div className="flex items-center justify-between pb-1">
          <h2
            className="text-base font-semibold text-text-primary"
            style={{ fontStretch: "expanded" }}
          >
            Library
          </h2>
          <div className="flex items-center gap-2">
            {/* Segmented filter (native All / Enabled / Disabled). */}
            <div className="flex rounded-capsule border border-border-subtle p-0.5">
              {(["all", "enabled", "disabled"] as Filter[]).map((f) => (
                <button
                  key={f}
                  data-testid={`project-filter-${f}`}
                  className={cn(
                    "rounded-capsule px-2.5 py-0.5 text-xs capitalize",
                    filter === f
                      ? "bg-[var(--color-selection-fill)] text-text-primary"
                      : "text-text-muted hover:text-text-primary",
                  )}
                  onClick={() => setFilter(f)}
                >
                  {f}
                </button>
              ))}
            </div>
            <button
              data-testid="projects-add"
              className="flex h-7 w-7 items-center justify-center rounded-full shadow-capsule"
              style={{
                background:
                  "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
                color: "var(--color-accent-foreground)",
              }}
              title="Add project"
              onClick={() => void startAdd()}
            >
              <Plus size={14} />
            </button>
          </div>
        </div>
        <p className="pb-3 text-xs text-text-muted">
          Registered project folders. Disabled projects are hidden from the sidebar and can't host
          new sessions; hiding removes the entry without touching files.
        </p>

        {adding ? (
          <div className="mb-3 flex gap-2">
            <input
              autoFocus
              data-testid="projects-add-path"
              className="min-w-0 flex-1 rounded-lg border border-border-strong bg-surface px-2.5 py-1.5 font-mono text-xs text-text-primary outline-none focus:border-accent"
              placeholder="/path/to/project"
              value={draftPath}
              onChange={(event) => setDraftPath(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter" && draftPath.trim()) {
                  void addProject(draftPath.trim()).then(() => {
                    setDraftPath("");
                    setAdding(false);
                  });
                }
                if (event.key === "Escape") setAdding(false);
              }}
            />
            <button
              data-testid="projects-add-confirm"
              className="rounded-capsule px-3 py-1.5 text-xs font-medium shadow-capsule disabled:opacity-40"
              style={{
                background:
                  "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
                color: "var(--color-accent-foreground)",
              }}
              disabled={!draftPath.trim()}
              onClick={() =>
                void addProject(draftPath.trim()).then(() => {
                  setDraftPath("");
                  setAdding(false);
                })
              }
            >
              Add
            </button>
          </div>
        ) : null}

        <div className="space-y-2">
          {visible.map((project) => {
            const enabled = isEnabled(project);
            const active = project.id === currentProjectId;
            return (
              <div
                key={project.id}
                className={cn(
                  "flex items-center gap-3 rounded-[14px] border border-border-subtle bg-surface px-3.5 py-2.5",
                  !enabled && "opacity-60 saturate-50",
                )}
                data-testid="project-row"
                data-project-name={project.name}
              >
                <ProjectTypeIcon
                  type={project.type}
                  size={20}
                  className="shrink-0 text-text-secondary"
                />
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-2">
                    <span
                      className="truncate text-sm font-semibold text-text-primary"
                      style={{ fontStretch: "expanded" }}
                    >
                      {project.name}
                    </span>
                    {project.type && project.type !== "unknown" && project.type !== "git" ? (
                      <span
                        className="rounded-capsule border border-border-subtle px-1.5 text-[10px] text-text-muted"
                        data-testid="project-type-badge"
                      >
                        {project.type}
                      </span>
                    ) : null}
                    {project.path.includes("github") ? <Github size={12} /> : null}
                    {active ? (
                      <span
                        className="rounded-capsule border px-1.5 py-0 text-[10px] font-medium"
                        style={{
                          color: "var(--color-brand-accent)",
                          borderColor: "var(--color-brand-accent)",
                        }}
                        data-testid="project-active-tag"
                      >
                        Active
                      </span>
                    ) : null}
                  </div>
                  <div
                    className="truncate font-mono text-[11px] text-text-muted"
                    style={{ direction: "rtl", textAlign: "left" }}
                    title={project.path}
                  >
                    {project.path}
                  </div>
                </div>
                <RecapButton
                  icon={Send}
                  title="Default agent"
                  count={project.defaultAgentName ? 1 : 0}
                />
                <RecapButton
                  icon={WandSparkles}
                  title="Assigned skills"
                  count={project.assignedSkills?.length ?? 0}
                />
                {/* The active session's project can't be disabled or hidden. */}
                <span title={active ? "Can't change the active project" : undefined}>
                  <Switch
                    checked={enabled}
                    disabled={active}
                    testid={`project-enabled-${project.name}`}
                    onChange={(next) => void updateProject(project.id, { enabled: next })}
                  />
                </span>
                <button
                  data-testid={`project-hide-${project.name}`}
                  className="rounded-capsule p-1.5 text-text-muted hover:text-[var(--color-role-error)] disabled:opacity-30 disabled:hover:text-text-muted"
                  title={active ? "Can't hide the active project" : "Hide from list"}
                  disabled={active}
                  onClick={() => void hide(project)}
                >
                  <EyeOff size={14} />
                </button>
              </div>
            );
          })}
          {visible.length === 0 ? (
            <div className="py-6 text-center text-sm text-text-muted">
              No projects {filter !== "all" ? `(${filter})` : ""} — add one with +.
            </div>
          ) : null}
        </div>
      </div>
    </div>
  );
}
