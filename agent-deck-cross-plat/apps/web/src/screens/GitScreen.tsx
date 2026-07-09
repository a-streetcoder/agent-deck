import { useCallback, useEffect, useState } from "react";
import { GitBranch, Sparkles } from "lucide-react";
import { useAppStore } from "../state/store.ts";

/**
 * Git screen (native GitRepositoryService): the current project's working-tree
 * status and a commit-all action. Project-scoped — git runs in the project's
 * path. Push/remote is a follow-up; this is see-changes + commit.
 */
interface GitFileChange {
  status: string;
  path: string;
}
interface GitStatus {
  repo: boolean;
  branch?: string;
  files: GitFileChange[];
  clean: boolean;
}

export function GitScreen() {
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const session = useAppStore((state) => state.session);
  const pushToast = useAppStore((state) => state.pushToast);
  const resourcesVersion = useAppStore((state) => state.resourcesVersion);
  const setError = useAppStore((state) => state.setError);
  const [status, setStatus] = useState<GitStatus | null>(null);
  const [message, setMessage] = useState("");
  const [committing, setCommitting] = useState(false);
  const [pushing, setPushing] = useState(false);
  const [generating, setGenerating] = useState(false);
  const [merging, setMerging] = useState(false);
  // Native piAgentGitAutomationEnabled: gates the Commit/Push/Merge actions
  // (default on). Off → the screen stays a read-only status view. `null` until
  // the setting loads, so neither the actions nor the "off" note flashes first
  // (a flash of enabled actions could let a quick click fire while off).
  const [gitActions, setGitActions] = useState<boolean | null>(null);

  const load = useCallback(async (): Promise<void> => {
    if (!currentProjectId) return;
    try {
      const response = await fetch(`/projects/${encodeURIComponent(currentProjectId)}/git/status`);
      if (!response.ok) throw new Error(await response.text());
      setStatus((await response.json()) as GitStatus);
    } catch (err) {
      setError(String(err));
    }
  }, [currentProjectId, setError]);

  useEffect(() => {
    void load();
  }, [load, resourcesVersion]);

  // Whether the git ACTIONS are enabled (native git-automation setting). Read on
  // mount — the screen mounts on nav, so a toggle in onboarding is picked up next
  // time you open Git.
  useEffect(() => {
    void fetch("/settings")
      .then((response) => response.json())
      .then((data: { settings: { gitAutomation: boolean } }) =>
        setGitActions(data.settings.gitAutomation),
      )
      .catch(() => {});
  }, []);

  const commit = async (push: boolean): Promise<void> => {
    if (!currentProjectId || !message.trim()) return;
    setCommitting(true);
    setError(null);
    try {
      const response = await fetch(`/projects/${encodeURIComponent(currentProjectId)}/git/commit`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ message: message.trim(), push }),
      });
      if (!response.ok) throw new Error(await response.text());
      setMessage("");
      pushToast({ kind: "success", message: push ? "Committed & pushed" : "Committed" });
      await load();
    } catch (err) {
      setError(String(err));
    } finally {
      setCommitting(false);
    }
  };

  const generateMessage = async (): Promise<void> => {
    if (!currentProjectId) return;
    setGenerating(true);
    setError(null);
    try {
      const response = await fetch(
        `/projects/${encodeURIComponent(currentProjectId)}/git/generate-message`,
        { method: "POST" },
      );
      if (!response.ok) throw new Error(await response.text());
      const { message: generated } = (await response.json()) as { message: string };
      setMessage(generated);
    } catch (err) {
      setError(String(err));
    } finally {
      setGenerating(false);
    }
  };

  const push = async (): Promise<void> => {
    if (!currentProjectId) return;
    setPushing(true);
    setError(null);
    try {
      const response = await fetch(`/projects/${encodeURIComponent(currentProjectId)}/git/push`, {
        method: "POST",
      });
      if (!response.ok) throw new Error(await response.text());
    } catch (err) {
      setError(String(err));
    } finally {
      setPushing(false);
    }
  };

  // Merge the current session's isolated worktree back into its source branch
  // (native Merge). Only shown when the session runs in a worktree.
  const merge = async (): Promise<void> => {
    if (!session?.id) return;
    setMerging(true);
    setError(null);
    try {
      const response = await fetch(`/sessions/${encodeURIComponent(session.id)}/merge`, {
        method: "POST",
      });
      if (!response.ok) throw new Error(await response.text());
      const { sourceBranch } = (await response.json()) as { sourceBranch: string };
      pushToast({ kind: "success", message: `Merged into ${sourceBranch}` });
      void load();
    } catch (err) {
      setError(String(err));
    } finally {
      setMerging(false);
    }
  };

  if (!currentProjectId) {
    return (
      <div className="min-h-0 flex-1 overflow-y-auto px-6 py-5" data-testid="git-screen">
        <div
          className="mx-auto max-w-3xl py-10 text-center text-sm text-text-muted"
          data-testid="git-no-project"
        >
          Git is project-scoped. Open a project to see its changes and commit.
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-0 flex-1 overflow-y-auto px-6 py-5" data-testid="git-screen">
      <div className="mx-auto max-w-3xl">
        <div className="flex items-center gap-2 pb-1">
          <GitBranch size={16} className="text-text-secondary" aria-hidden />
          <h2
            className="text-base font-semibold text-text-primary"
            style={{ fontStretch: "expanded" }}
          >
            Git
          </h2>
          {status?.repo && status.branch ? (
            <span
              data-testid="git-branch"
              className="rounded-capsule border border-border-strong px-2 py-0.5 font-mono text-[11px] text-text-secondary"
            >
              {status.branch}
            </span>
          ) : null}
        </div>

        {gitActions === true && session?.worktreeBranch && session.worktreeSourceBranch ? (
          <div
            data-testid="git-worktree-banner"
            className="mb-3 mt-1 flex items-center justify-between gap-3 rounded-lg border border-border-subtle bg-surface px-3 py-2.5"
          >
            <div className="min-w-0 text-xs text-text-secondary">
              This session is isolated on{" "}
              <span className="font-mono text-text-primary">{session.worktreeBranch}</span>. Merge
              brings its commits back into{" "}
              <span className="font-mono text-text-primary">{session.worktreeSourceBranch}</span>.
            </div>
            <button
              data-testid="git-merge"
              className="shrink-0 rounded-capsule px-3 py-1.5 text-xs font-medium shadow-capsule disabled:opacity-40"
              style={{
                background:
                  "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
                color: "var(--color-accent-foreground)",
              }}
              disabled={merging}
              onClick={() => void merge()}
            >
              {merging ? "Merging…" : `Merge to ${session.worktreeSourceBranch}`}
            </button>
          </div>
        ) : null}

        {status && !status.repo ? (
          <div className="py-10 text-center text-sm text-text-muted" data-testid="git-not-repo">
            This project isn&apos;t a git repository.
          </div>
        ) : (
          <>
            <p className="pb-3 text-xs text-text-muted">
              Uncommitted changes in the project working tree. Commit stages everything (git add -A)
              and commits with your message.
            </p>

            <div className="space-y-1" data-testid="git-file-list">
              {(status?.files ?? []).map((file) => (
                <div
                  key={file.path}
                  data-git-path={file.path}
                  className="flex items-center gap-3 rounded-[12px] border border-border-subtle bg-surface px-3 py-1.5"
                >
                  <span className="w-6 shrink-0 font-mono text-[11px] text-[var(--color-brand-accent)]">
                    {file.status.trim() || "•"}
                  </span>
                  <span className="truncate font-mono text-[12px] text-text-primary">
                    {file.path}
                  </span>
                </div>
              ))}
              {status?.clean ? (
                <div className="py-8 text-center text-sm text-text-muted" data-testid="git-clean">
                  Working tree clean — nothing to commit.
                </div>
              ) : null}
            </div>

            {gitActions === false ? (
              <div
                data-testid="git-actions-off"
                className="mt-4 rounded-lg border border-border-subtle bg-surface px-3 py-2.5 text-xs text-text-muted"
              >
                Git actions are turned off. Enable Commit / Push actions in the welcome flow&apos;s
                Preferences to commit from here.
              </div>
            ) : gitActions === null ? null : (
              <div className="mt-4 flex flex-col gap-2">
                <textarea
                  data-testid="git-commit-message"
                  className="min-h-[64px] w-full rounded-lg border border-border-strong bg-surface px-2.5 py-1.5 text-sm text-text-primary outline-none focus:border-accent"
                  placeholder="Commit message"
                  value={message}
                  onChange={(e) => setMessage(e.target.value)}
                />
                <div className="flex items-center justify-end gap-2">
                  <button
                    data-testid="git-generate-message"
                    className="mr-auto flex items-center gap-1 rounded-capsule border border-border-strong px-3 py-1.5 text-sm text-text-secondary hover:text-text-primary disabled:opacity-40"
                    disabled={generating || committing || status?.clean}
                    onClick={() => void generateMessage()}
                    title="Draft a commit message from your changes"
                  >
                    <Sparkles size={12} /> {generating ? "Generating…" : "Generate"}
                  </button>
                  <button
                    data-testid="git-push"
                    className="rounded-capsule border border-border-strong px-3 py-1.5 text-sm text-text-secondary hover:text-text-primary disabled:opacity-40"
                    disabled={committing || pushing}
                    onClick={() => void push()}
                    title="Push the current branch's commits"
                  >
                    {pushing ? "Pushing…" : "Push"}
                  </button>
                  <button
                    data-testid="git-commit"
                    className="rounded-capsule border border-border-strong px-3 py-1.5 text-sm text-text-secondary hover:text-text-primary disabled:opacity-40"
                    disabled={committing || status?.clean || !message.trim()}
                    onClick={() => void commit(false)}
                  >
                    {committing ? "Committing…" : "Commit all"}
                  </button>
                  <button
                    data-testid="git-commit-push"
                    className="rounded-capsule px-4 py-1.5 text-sm font-medium shadow-capsule disabled:opacity-40"
                    style={{
                      background:
                        "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
                      color: "var(--color-accent-foreground)",
                    }}
                    disabled={committing || status?.clean || !message.trim()}
                    onClick={() => void commit(true)}
                  >
                    Commit &amp; Push
                  </button>
                </div>
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}
