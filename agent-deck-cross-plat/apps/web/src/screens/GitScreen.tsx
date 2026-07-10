import { useCallback, useEffect, useState } from "react";
import { GitBranch, Sparkles, Tag } from "lucide-react";
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
type ReleaseBump = "patch" | "minor" | "major";
interface ReleasePreflight {
  branch: string | null;
  latestTag: string | null;
  nextVersions: Record<ReleaseBump, string>;
  blocker: string | null;
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
  // Native ReleaseService (generalized to any repo): tag a version + AI notes.
  const [releaseOpen, setReleaseOpen] = useState(false);
  const [preflight, setPreflight] = useState<ReleasePreflight | null>(null);
  const [bump, setBump] = useState<ReleaseBump>("patch");
  const [notes, setNotes] = useState("");
  const [preflighting, setPreflighting] = useState(false);
  const [draftingNotes, setDraftingNotes] = useState(false);
  const [releasing, setReleasing] = useState(false);

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

  // Open the release panel and load preflight (latest tag + proposed versions).
  const openRelease = async (): Promise<void> => {
    if (!currentProjectId) return;
    setReleaseOpen(true);
    setPreflighting(true);
    setError(null);
    try {
      const response = await fetch(
        `/projects/${encodeURIComponent(currentProjectId)}/release/preflight`,
      );
      if (!response.ok) throw new Error(await response.text());
      const data = (await response.json()) as ReleasePreflight;
      setPreflight(data);
    } catch (err) {
      setError(String(err));
      setReleaseOpen(false);
    } finally {
      setPreflighting(false);
    }
  };

  const draftNotes = async (): Promise<void> => {
    if (!currentProjectId || !preflight) return;
    setDraftingNotes(true);
    setError(null);
    try {
      const response = await fetch(
        `/projects/${encodeURIComponent(currentProjectId)}/release/notes`,
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ version: preflight.nextVersions[bump] }),
        },
      );
      if (!response.ok) throw new Error(await response.text());
      const { notes: drafted } = (await response.json()) as { notes: string };
      setNotes(drafted);
    } catch (err) {
      setError(String(err));
    } finally {
      setDraftingNotes(false);
    }
  };

  const release = async (): Promise<void> => {
    if (!currentProjectId || !preflight) return;
    const tag = preflight.nextVersions[bump];
    setReleasing(true);
    setError(null);
    try {
      const response = await fetch(`/projects/${encodeURIComponent(currentProjectId)}/release`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ tag, notes: notes.trim() || undefined }),
      });
      if (!response.ok) {
        if (response.status === 409) throw new Error(`${tag} already exists.`);
        throw new Error(await response.text());
      }
      pushToast({ kind: "success", message: `Released ${tag}` });
      setReleaseOpen(false);
      setPreflight(null);
      setNotes("");
    } catch (err) {
      setError(String(err));
    } finally {
      setReleasing(false);
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
          {gitActions === true && status?.repo && !releaseOpen ? (
            <button
              data-testid="git-release"
              className="ml-auto flex items-center gap-1 rounded-capsule border border-border-strong px-3 py-1 text-xs text-text-secondary hover:text-text-primary disabled:opacity-40"
              disabled={preflighting}
              onClick={() => void openRelease()}
              title="Tag a version and generate release notes"
            >
              <Tag size={12} /> {preflighting ? "Preparing…" : "Release"}
            </button>
          ) : null}
        </div>

        {releaseOpen ? (
          <div
            data-testid="git-release-panel"
            className="mb-3 mt-2 flex flex-col gap-3 rounded-lg border border-border-subtle bg-surface px-3.5 py-3"
          >
            <div className="flex items-center justify-between gap-2">
              <div className="text-xs text-text-secondary">
                {preflight?.latestTag ? (
                  <>
                    Latest release{" "}
                    <span className="font-mono text-text-primary">{preflight.latestTag}</span>
                  </>
                ) : (
                  "No releases yet — this will be the first."
                )}
              </div>
              <button
                data-testid="git-release-close"
                className="text-xs text-text-muted hover:text-text-primary"
                onClick={() => setReleaseOpen(false)}
              >
                Cancel
              </button>
            </div>

            {preflight?.blocker ? (
              <div
                data-testid="git-release-blocker"
                className="rounded-md border border-border-subtle bg-surface-raised px-2.5 py-2 text-xs text-text-muted"
              >
                {preflight.blocker}
              </div>
            ) : null}

            <div className="flex flex-wrap gap-2" role="radiogroup" aria-label="Version bump">
              {(["patch", "minor", "major"] as const).map((kind) => (
                <button
                  key={kind}
                  data-testid={`git-release-version-${kind}`}
                  role="radio"
                  aria-checked={bump === kind}
                  className={`flex-1 rounded-md border px-2.5 py-1.5 text-left text-xs ${
                    bump === kind
                      ? "border-accent text-text-primary"
                      : "border-border-subtle text-text-secondary hover:text-text-primary"
                  }`}
                  onClick={() => setBump(kind)}
                >
                  <div className="capitalize">{kind}</div>
                  <div className="font-mono text-[11px] text-text-muted">
                    {preflight?.nextVersions[kind] ?? "…"}
                  </div>
                </button>
              ))}
            </div>

            <div className="flex flex-col gap-2">
              <textarea
                data-testid="git-release-notes"
                className="min-h-[112px] w-full rounded-lg border border-border-strong bg-surface px-2.5 py-1.5 font-mono text-xs text-text-primary outline-none focus:border-accent"
                placeholder="Release notes (optional — Generate drafts them from your commits)"
                value={notes}
                onChange={(e) => setNotes(e.target.value)}
              />
              <div className="flex items-center justify-end gap-2">
                <button
                  data-testid="git-release-generate"
                  className="mr-auto flex items-center gap-1 rounded-capsule border border-border-strong px-3 py-1.5 text-xs text-text-secondary hover:text-text-primary disabled:opacity-40"
                  disabled={draftingNotes || releasing || !preflight}
                  onClick={() => void draftNotes()}
                  title="Draft release notes from commits since the last tag"
                >
                  <Sparkles size={12} /> {draftingNotes ? "Drafting…" : "Generate notes"}
                </button>
                <button
                  data-testid="git-release-confirm"
                  className="rounded-capsule px-4 py-1.5 text-xs font-medium shadow-capsule disabled:opacity-40"
                  style={{
                    background:
                      "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
                    color: "var(--color-accent-foreground)",
                  }}
                  disabled={releasing || !preflight || Boolean(preflight?.blocker)}
                  onClick={() => void release()}
                >
                  {releasing ? "Releasing…" : `Release ${preflight?.nextVersions[bump] ?? ""}`}
                </button>
              </div>
            </div>
          </div>
        ) : null}

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
