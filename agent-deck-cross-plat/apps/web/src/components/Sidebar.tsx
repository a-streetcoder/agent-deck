import { useState } from "react";
import { useAppStore } from "../state/store.ts";
import { addProject, newChat, switchToProject, switchToSession } from "../state/wsBridge.ts";

const VIEWS = [
  { id: "chat", label: "Pi Agent" },
  { id: "agents", label: "Agents" },
  { id: "skills", label: "Skills" },
] as const;

export function Sidebar() {
  const projects = useAppStore((state) => state.projects);
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const currentSession = useAppStore((state) => state.session);
  const sessions = useAppStore((state) => state.sessions);
  const view = useAppStore((state) => state.view);
  const setView = useAppStore((state) => state.setView);
  const [draftPath, setDraftPath] = useState("");
  const [adding, setAdding] = useState(false);

  const projectSessions = sessions
    .filter((s) => (s.projectId ?? null) === currentProjectId)
    .sort((a, b) => b.createdAt.localeCompare(a.createdAt));

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
        Workspace
      </div>
      <nav className="space-y-1 px-2 pb-2">
        {VIEWS.map((item) => (
          <button
            key={item.id}
            className={itemClass(view === item.id)}
            data-testid={`nav-${item.id}`}
            onClick={() => setView(item.id)}
          >
            {item.label}
          </button>
        ))}
      </nav>
      <div className="flex items-center justify-between px-4 pb-2 pt-4">
        <span className="text-xs font-semibold uppercase tracking-wider text-text-muted">
          Chats
        </span>
        <button
          data-testid="new-chat"
          className="rounded-capsule px-2 text-sm text-text-muted hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
          title="New chat"
          onClick={() => {
            setView("chat");
            void newChat();
          }}
        >
          +
        </button>
      </div>
      <nav className="max-h-48 space-y-1 overflow-y-auto px-2" data-testid="chat-list">
        {projectSessions.map((s) => (
          <button
            key={s.id}
            className={itemClass(view === "chat" && currentSession?.id === s.id)}
            data-testid={`chat-${s.id}`}
            title={s.agentName ? `agent: ${s.agentName}` : undefined}
            onClick={() => {
              setView("chat");
              void switchToSession(s);
            }}
          >
            <span data-testid="chat-title">{s.title ?? "New chat"}</span>
            {s.agentName ? (
              <span className="ml-1 text-xs text-text-muted">({s.agentName})</span>
            ) : null}
            {s.endedAt ? <span className="ml-1 text-xs text-text-muted">·ended</span> : null}
          </button>
        ))}
      </nav>
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
