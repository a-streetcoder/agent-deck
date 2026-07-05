import { useCallback, useEffect, useState } from "react";
import { CircleDot, RefreshCw } from "lucide-react";
import { useAppStore } from "../state/store.ts";
import { newChat } from "../state/wsBridge.ts";

/**
 * Issues screen (native Workspace → Issues): the current project's GitHub
 * issues via the gh CLI. Selecting one starts a new session seeded with a
 * prompt referencing the issue (native PiIssuePromptBuilder).
 */
interface Issue {
  number: number;
  title: string;
  state: string;
  url: string;
  labels: string[];
}

export function IssuesScreen() {
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const projects = useAppStore((state) => state.projects);
  const setView = useAppStore((state) => state.setView);
  const setPendingComposerText = useAppStore((state) => state.setPendingComposerText);
  const project = projects.find((p) => p.id === currentProjectId) ?? null;

  const [issues, setIssues] = useState<Issue[]>([]);
  const [error, setLocalError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const load = useCallback(async (projectId: string): Promise<void> => {
    setLoading(true);
    setLocalError(null);
    try {
      const response = await fetch(`/projects/${encodeURIComponent(projectId)}/issues`);
      const data = (await response.json()) as { issues?: Issue[]; error?: string };
      setIssues(data.issues ?? []);
      setLocalError(data.error ?? (response.ok ? null : "Couldn't load issues."));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (currentProjectId) void load(currentProjectId);
  }, [currentProjectId, load]);

  const start = async (issue: Issue): Promise<void> => {
    setView("chat");
    // Wait for the new session to become active before seeding its composer,
    // so the prompt can't land in the previous session's draft.
    await newChat();
    setPendingComposerText(
      `Work on GitHub issue #${issue.number}: ${issue.title}\n${issue.url}\n\n` +
        `Investigate the issue and propose a fix.`,
    );
  };

  if (!project) {
    return (
      <div
        className="flex min-h-0 flex-1 items-center justify-center px-6 py-5 text-center"
        data-testid="issues-screen"
      >
        <div className="max-w-sm text-sm text-text-muted" data-testid="issues-no-project">
          Issues are project-scoped. Select a project with a GitHub remote to see its issues.
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-0 flex-1 overflow-y-auto px-6 py-5" data-testid="issues-screen">
      <div className="mx-auto max-w-3xl">
        <div className="flex items-center justify-between pb-1">
          <div className="flex items-center gap-2">
            <CircleDot size={16} className="text-text-secondary" aria-hidden />
            <h2
              className="text-base font-semibold text-text-primary"
              style={{ fontStretch: "expanded" }}
            >
              {project.name} · Issues
            </h2>
          </div>
          <button
            data-testid="issues-refresh"
            className="flex items-center gap-1.5 rounded-capsule border border-border-strong px-2.5 py-0.5 text-xs text-text-secondary hover:text-text-primary disabled:opacity-40"
            disabled={loading}
            onClick={() => currentProjectId && void load(currentProjectId)}
          >
            <RefreshCw size={11} className={loading ? "animate-spin" : undefined} /> Refresh
          </button>
        </div>
        <p className="pb-3 text-xs text-text-muted">
          Open GitHub issues for this project. Select one to start a session on it.
        </p>

        {error ? (
          <div
            className="rounded-2xl border border-border-subtle bg-surface px-4 py-6 text-center text-sm text-text-muted"
            data-testid="issues-error"
          >
            {error}
          </div>
        ) : (
          <div className="space-y-1.5" data-testid="issues-list">
            {issues.map((issue) => (
              <button
                key={issue.number}
                data-testid={`issue-${issue.number}`}
                className="flex w-full items-center gap-3 rounded-[14px] border border-border-subtle bg-surface px-3.5 py-2.5 text-left hover:bg-[var(--color-hover-fill)]"
                onClick={() => void start(issue)}
              >
                <span className="font-mono text-xs text-text-muted">#{issue.number}</span>
                <span
                  className="min-w-0 flex-1 truncate text-sm font-medium text-text-primary"
                  style={{ fontStretch: "expanded" }}
                >
                  {issue.title}
                </span>
                {issue.labels.slice(0, 3).map((label) => (
                  <span
                    key={label}
                    className="shrink-0 rounded-capsule border border-border-subtle px-1.5 text-[10px] text-text-muted"
                  >
                    {label}
                  </span>
                ))}
              </button>
            ))}
            {issues.length === 0 && !loading ? (
              <div className="py-8 text-center text-sm text-text-muted">No open issues.</div>
            ) : null}
          </div>
        )}
      </div>
    </div>
  );
}
