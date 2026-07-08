import { useCallback, useEffect, useState } from "react";
import { GitBranch } from "lucide-react";
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
  const resourcesVersion = useAppStore((state) => state.resourcesVersion);
  const setError = useAppStore((state) => state.setError);
  const [status, setStatus] = useState<GitStatus | null>(null);
  const [message, setMessage] = useState("");
  const [committing, setCommitting] = useState(false);
  const [pushing, setPushing] = useState(false);

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
      await load();
    } catch (err) {
      setError(String(err));
    } finally {
      setCommitting(false);
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
          </>
        )}
      </div>
    </div>
  );
}
