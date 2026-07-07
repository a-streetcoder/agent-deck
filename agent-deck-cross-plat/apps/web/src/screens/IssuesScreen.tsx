import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import {
  ArrowLeft,
  CheckCircle2,
  CircleDot,
  CircleSlash,
  MessageSquare,
  PenLine,
  RefreshCw,
  Sparkles,
  User,
} from "lucide-react";
import { cn } from "@/lib/cn";
import { MarkdownDocument } from "@/design-system/markdown/MarkdownDocument";
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
  assignees: string[];
  author: string | null;
}

interface IssueComment {
  author: string | null;
  body: string;
  createdAt: string | null;
}

interface IssueDetail extends Issue {
  body: string;
  comments: IssueComment[];
}

/** ISO timestamp → a short local date, or "" if absent/unparseable. */
function formatDate(iso: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  return Number.isNaN(d.getTime())
    ? ""
    : d.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

export function IssuesScreen() {
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const projects = useAppStore((state) => state.projects);
  const setView = useAppStore((state) => state.setView);
  const setGlobalError = useAppStore((state) => state.setError);
  const setPendingComposerText = useAppStore((state) => state.setPendingComposerText);
  const project = projects.find((p) => p.id === currentProjectId) ?? null;

  const [issues, setIssues] = useState<Issue[]>([]);
  const [error, setLocalError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  // Native Issues screen's Open / Closed / All segmented filter.
  const [stateFilter, setStateFilter] = useState<"open" | "closed" | "all">("open");
  // Native client-side facet filters (AppViewModel.filteredBoardItems): labels
  // are multi-select with OR semantics (an issue passes if it shares ≥1 selected
  // label — native `labels.isDisjoint(with:)`); assignee is single-select. Both
  // filter the already-loaded board, never re-query gh.
  const [labelFilters, setLabelFilters] = useState<string[]>([]);
  const [assigneeFilter, setAssigneeFilter] = useState<string | null>(null);
  // Native single-select author/creator filter (githubAuthorFilter).
  const [authorFilter, setAuthorFilter] = useState<string | null>(null);
  // Native free-text search (IssuesScreen.searchFiltered): a lowercased substring
  // match over each item's searchableHaystack, applied AFTER the facet filters.
  const [searchQuery, setSearchQuery] = useState("");
  // Monotonic request token: a slow fetch for a stale project/filter must not
  // clobber the result of a newer one (the filter buttons stay clickable).
  const reqRef = useRef(0);
  // The open issue detail pane (native GitHubIssueDetailView), or null for the list.
  const [detail, setDetail] = useState<IssueDetail | null>(null);
  const [detailNumber, setDetailNumber] = useState<number | null>(null);
  const [detailError, setDetailError] = useState<string | null>(null);
  const detailReq = useRef(0);

  const load = useCallback(
    async (projectId: string): Promise<void> => {
      const req = ++reqRef.current;
      setLoading(true);
      setLocalError(null);
      try {
        const response = await fetch(
          `/projects/${encodeURIComponent(projectId)}/issues?state=${stateFilter}`,
        );
        const data = (await response.json()) as { issues?: Issue[]; error?: string };
        if (reqRef.current !== req) return; // a newer load superseded this one
        setIssues(data.issues ?? []);
        setLocalError(data.error ?? (response.ok ? null : "Couldn't load issues."));
      } finally {
        if (reqRef.current === req) setLoading(false);
      }
    },
    [stateFilter],
  );

  useEffect(() => {
    if (currentProjectId) void load(currentProjectId);
  }, [currentProjectId, load]);

  // Switching projects: everything on screen (list rows AND any open detail)
  // belonged to the old repo. Reset in a LAYOUT effect so it lands before the
  // browser paints — no stale-issue flash — and abandon any in-flight fetches
  // so a slow response for the old project can't repopulate the new one.
  useLayoutEffect(() => {
    reqRef.current++;
    detailReq.current++;
    setIssues([]);
    setDetailNumber(null);
    setDetail(null);
    setDetailError(null);
    setLocalError(null);
    // The old repo's labels/assignees/authors don't apply to the new one.
    setLabelFilters([]);
    setAssigneeFilter(null);
    setAuthorFilter(null);
    setSearchQuery("");
  }, [currentProjectId]);

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

  // Load a single issue's detail (title/state/labels/assignees/author/body).
  const openDetail = async (number: number): Promise<void> => {
    if (!currentProjectId) return;
    const req = ++detailReq.current;
    setDetailNumber(number);
    setDetail(null);
    setDetailError(null);
    try {
      const res = await fetch(`/projects/${encodeURIComponent(currentProjectId)}/issues/${number}`);
      if (detailReq.current !== req) return; // a newer open superseded this one
      if (!res.ok) {
        const { error } = (await res.json().catch(() => ({}))) as { error?: string };
        setDetailError(error ?? "Couldn't load the issue.");
        return;
      }
      const { issue } = (await res.json()) as { issue: IssueDetail };
      if (detailReq.current === req) setDetail(issue);
    } catch (err) {
      if (detailReq.current === req) setDetailError(String(err));
    }
  };

  const closeDetail = (): void => {
    detailReq.current++; // abandon any in-flight detail fetch
    setDetailNumber(null);
    setDetail(null);
    setDetailError(null);
  };

  // Close the open issue (native 10.9 split-button: completed / not planned).
  const closeIssue = async (reason: "completed" | "not_planned"): Promise<void> => {
    if (!currentProjectId || !detail) return;
    // Token identifies the current selection (bumped on project switch AND on
    // opening any issue), so a delayed response can't touch a newer selection —
    // e.g. the SAME issue number in a different project after a switch.
    const req = detailReq.current;
    const res = await fetch(
      `/projects/${encodeURIComponent(currentProjectId)}/issues/${detail.number}/close`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ reason }),
      },
    );
    if (detailReq.current !== req) return; // selection changed — ignore this response
    if (!res.ok) {
      const { error } = (await res.json().catch(() => ({}))) as { error?: string };
      // Surface on the GLOBAL banner, NOT the detail-error slot — a failed close
      // must keep the still-open issue (and its close buttons) on screen.
      setGlobalError(error ?? "Couldn't close the issue.");
      return;
    }
    // Reflect the close locally (the list re-filters by the server's state on
    // its next load).
    setDetail((current) => (current ? { ...current, state: "CLOSED" } : current));
  };

  // Facets derived from the loaded board (native githubAvailableLabels /
  // githubAvailableAssignees): deduped, case-insensitively sorted.
  const sortCI = (a: string, b: string): number =>
    a.localeCompare(b, undefined, { sensitivity: "base" });
  const availableLabels = useMemo(
    () => [...new Set(issues.flatMap((i) => i.labels))].sort(sortCI),
    [issues],
  );
  const availableAssignees = useMemo(
    () => [...new Set(issues.flatMap((i) => i.assignees))].sort(sortCI),
    [issues],
  );
  const availableAuthors = useMemo(
    () => [...new Set(issues.flatMap((i) => (i.author ? [i.author] : [])))].sort(sortCI),
    [issues],
  );

  // Client-side filter (native filteredBoardItems + searchFiltered): label OR +
  // assignee contains, then a lowercased substring search over the item's
  // haystack. The list model carries title/number/labels/assignees (body/author
  // are detail-only), so the haystack is that faithful subset of native's.
  const search = searchQuery.trim().toLowerCase();
  const visibleIssues = useMemo(
    () =>
      issues.filter((issue) => {
        if (authorFilter && issue.author !== authorFilter) return false;
        if (assigneeFilter && !issue.assignees.includes(assigneeFilter)) return false;
        if (labelFilters.length && !labelFilters.some((l) => issue.labels.includes(l)))
          return false;
        if (search) {
          const haystack = [
            issue.title,
            `#${issue.number}`,
            issue.author ?? "",
            ...issue.assignees,
            ...issue.labels,
          ]
            .join(" ")
            .toLowerCase();
          if (!haystack.includes(search)) return false;
        }
        return true;
      }),
    [issues, authorFilter, assigneeFilter, labelFilters, search],
  );
  const filtersActive = labelFilters.length > 0 || assigneeFilter !== null || authorFilter !== null;
  const clearFilters = (): void => {
    setLabelFilters([]);
    setAssigneeFilter(null);
    setAuthorFilter(null);
  };

  // Prune selections that no longer exist in the reloaded board (e.g. after a
  // state-filter switch drops the labels/assignees they referenced), so a stale
  // chip can't keep the list mysteriously empty. Mirrors native resetIssueFilters
  // being scoped to what's actually present.
  useEffect(() => {
    setLabelFilters((prev) => {
      const next = prev.filter((l) => availableLabels.includes(l));
      return next.length === prev.length ? prev : next;
    });
    setAssigneeFilter((prev) => (prev && !availableAssignees.includes(prev) ? null : prev));
    setAuthorFilter((prev) => (prev && !availableAuthors.includes(prev) ? null : prev));
  }, [availableLabels, availableAssignees, availableAuthors]);

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
        {detailNumber !== null ? (
          <div data-testid="issue-detail">
            <button
              data-testid="issue-detail-back"
              className="flex items-center gap-1 pb-3 text-xs text-text-muted hover:text-text-primary"
              onClick={closeDetail}
            >
              <ArrowLeft size={13} /> Back to issues
            </button>
            {detailError ? (
              <div
                className="rounded-2xl border border-border-subtle bg-surface px-4 py-6 text-center text-sm text-text-muted"
                data-testid="issue-detail-error"
              >
                {detailError}
              </div>
            ) : !detail ? (
              <div className="py-8 text-center text-sm text-text-muted">
                Loading issue #{detailNumber}…
              </div>
            ) : (
              <>
                <div className="flex items-center gap-2 pb-1">
                  <span
                    data-testid="issue-detail-state"
                    data-state={detail.state.toLowerCase()}
                    className={cn(
                      "rounded-capsule border px-2 py-0.5 text-[11px] capitalize",
                      detail.state.toLowerCase() === "open"
                        ? "border-[var(--color-role-success)] text-[var(--color-role-success)]"
                        : "border-border-strong text-text-muted",
                    )}
                  >
                    {detail.state.toLowerCase()}
                  </span>
                  <span className="font-mono text-xs text-text-muted">#{detail.number}</span>
                </div>
                <h2
                  className="text-lg font-semibold text-text-primary"
                  style={{ fontStretch: "expanded" }}
                >
                  {detail.title}
                </h2>
                <div className="flex flex-wrap items-center gap-2 pt-1.5 text-[11px] text-text-muted">
                  {detail.author ? (
                    <span className="flex items-center gap-1">
                      <User size={11} /> {detail.author}
                    </span>
                  ) : null}
                  {detail.assignees.length ? (
                    <span data-testid="issue-detail-assignees">
                      assigned: {detail.assignees.join(", ")}
                    </span>
                  ) : null}
                  {detail.labels.map((label) => (
                    <span
                      key={label}
                      className="rounded-capsule border border-border-subtle px-1.5"
                    >
                      {label}
                    </span>
                  ))}
                </div>
                <div className="mt-3 flex flex-wrap items-center gap-2">
                  <button
                    data-testid="issue-open-in-pi"
                    className="flex items-center gap-1.5 rounded-capsule px-3 py-1 text-xs font-medium shadow-capsule"
                    style={{
                      background:
                        "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
                      color: "var(--color-accent-foreground)",
                    }}
                    onClick={() => void start(detail)}
                  >
                    <Sparkles size={13} /> Open in Pi
                  </button>
                  {detail.state.toLowerCase() === "open" ? (
                    <>
                      <button
                        data-testid="issue-close-completed"
                        className="flex items-center gap-1.5 rounded-capsule border border-border-strong px-2.5 py-1 text-xs text-text-secondary hover:text-text-primary"
                        onClick={() => void closeIssue("completed")}
                      >
                        <CheckCircle2 size={13} /> Close as completed
                      </button>
                      <button
                        data-testid="issue-close-not-planned"
                        className="flex items-center gap-1.5 rounded-capsule border border-border-strong px-2.5 py-1 text-xs text-text-muted hover:text-text-primary"
                        onClick={() => void closeIssue("not_planned")}
                      >
                        <CircleSlash size={13} /> Not planned
                      </button>
                    </>
                  ) : null}
                </div>
                <div
                  className="mt-4 rounded-xl border border-border-subtle bg-surface-elevated px-4 py-3"
                  data-testid="issue-detail-body"
                >
                  <MarkdownDocument source={detail.body || "_No description provided._"} />
                </div>

                <div className="mt-5" data-testid="issue-comments">
                  <div className="flex items-center gap-1.5 pb-2 text-[10px] font-semibold uppercase tracking-wider text-text-muted">
                    <MessageSquare size={12} /> Comments
                    <span className="rounded-capsule border border-border-subtle px-1 tabular-nums">
                      {detail.comments.length}
                    </span>
                  </div>
                  {detail.comments.length === 0 ? (
                    <div className="text-xs text-text-muted">No comments yet.</div>
                  ) : (
                    <div className="space-y-2">
                      {detail.comments.map((comment, i) => (
                        <div
                          key={i}
                          data-testid="issue-comment"
                          className="rounded-xl border border-border-subtle bg-surface px-4 py-2.5"
                        >
                          <div className="flex items-center gap-2 pb-1 text-[11px] text-text-muted">
                            <span className="flex items-center gap-1 font-medium text-text-secondary">
                              <User size={11} /> {comment.author ?? "unknown"}
                            </span>
                            {formatDate(comment.createdAt) ? (
                              <span>{formatDate(comment.createdAt)}</span>
                            ) : null}
                          </div>
                          <MarkdownDocument source={comment.body || "_(empty)_"} />
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              </>
            )}
          </div>
        ) : (
          <>
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
              <div className="flex items-center gap-2">
                <div
                  className="flex items-center gap-0.5 rounded-capsule border border-border-subtle p-0.5"
                  role="group"
                  aria-label="Filter issues by state"
                >
                  {(["open", "closed", "all"] as const).map((s) => (
                    <button
                      key={s}
                      data-testid={`issues-state-${s}`}
                      aria-pressed={stateFilter === s}
                      className={cn(
                        "rounded-capsule px-2.5 py-0.5 text-xs capitalize transition-colors",
                        stateFilter === s
                          ? "bg-[var(--color-selection-fill)] text-text-primary"
                          : "text-text-muted hover:text-text-primary",
                      )}
                      onClick={() => setStateFilter(s)}
                    >
                      {s}
                    </button>
                  ))}
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
            </div>
            <p className="pb-3 text-xs text-text-muted">
              {stateFilter === "all"
                ? "All GitHub issues for this project."
                : `${stateFilter === "open" ? "Open" : "Closed"} GitHub issues for this project.`}{" "}
              Select one to start a session on it.
            </p>

            {/* Native free-text search (searchableHaystack): filters the loaded
                board client-side by title / #number / labels / assignees. */}
            {!error ? (
              <input
                data-testid="issues-search"
                className="mb-3 w-full rounded-lg border border-border-subtle bg-surface px-2.5 py-1.5 text-sm text-text-primary outline-none focus:border-accent"
                placeholder="Search issues by title, #number, label, assignee, or author…"
                value={searchQuery}
                onChange={(event) => setSearchQuery(event.target.value)}
              />
            ) : null}

            {/* Native label + assignee + author facet filters (client-side over
                the loaded board). Only shown when the board offers a facet. */}
            {!error &&
            (availableLabels.length > 0 ||
              availableAssignees.length > 0 ||
              availableAuthors.length > 0) ? (
              <div className="flex flex-wrap items-center gap-1.5 pb-3" data-testid="issues-facets">
                {availableAuthors.length > 0 ? (
                  <div className="flex items-center gap-1" data-testid="issues-author-filter">
                    <PenLine size={12} className="text-text-muted" aria-hidden />
                    {availableAuthors.map((author) => {
                      const on = authorFilter === author;
                      return (
                        <button
                          key={author}
                          data-testid={`issues-author-${author}`}
                          aria-pressed={on}
                          className={cn(
                            "rounded-capsule border px-2 py-0.5 text-[11px] transition-colors",
                            on
                              ? "border-border-strong bg-[var(--color-selection-fill)] text-text-primary"
                              : "border-border-subtle text-text-muted hover:text-text-primary",
                          )}
                          onClick={() => setAuthorFilter(on ? null : author)}
                        >
                          {author}
                        </button>
                      );
                    })}
                  </div>
                ) : null}
                {availableAssignees.length > 0 ? (
                  <div className="flex items-center gap-1" data-testid="issues-assignee-filter">
                    <User size={12} className="text-text-muted" aria-hidden />
                    {availableAssignees.map((assignee) => {
                      const on = assigneeFilter === assignee;
                      return (
                        <button
                          key={assignee}
                          data-testid={`issues-assignee-${assignee}`}
                          aria-pressed={on}
                          className={cn(
                            "rounded-capsule border px-2 py-0.5 text-[11px] transition-colors",
                            on
                              ? "border-border-strong bg-[var(--color-selection-fill)] text-text-primary"
                              : "border-border-subtle text-text-muted hover:text-text-primary",
                          )}
                          onClick={() => setAssigneeFilter(on ? null : assignee)}
                        >
                          {assignee}
                        </button>
                      );
                    })}
                  </div>
                ) : null}
                {availableLabels.map((label) => {
                  const on = labelFilters.includes(label);
                  return (
                    <button
                      key={label}
                      data-testid={`issues-label-${label}`}
                      aria-pressed={on}
                      className={cn(
                        "rounded-capsule border px-2 py-0.5 text-[11px] transition-colors",
                        on
                          ? "border-border-strong bg-[var(--color-selection-fill)] text-text-primary"
                          : "border-border-subtle text-text-muted hover:text-text-primary",
                      )}
                      onClick={() =>
                        setLabelFilters((prev) =>
                          prev.includes(label) ? prev.filter((l) => l !== label) : [...prev, label],
                        )
                      }
                    >
                      {label}
                    </button>
                  );
                })}
                {filtersActive ? (
                  <button
                    data-testid="issues-clear-filters"
                    className="rounded-capsule px-2 py-0.5 text-[11px] text-text-muted underline-offset-2 hover:text-text-primary hover:underline"
                    onClick={clearFilters}
                  >
                    Clear filters
                  </button>
                ) : null}
              </div>
            ) : null}

            {error ? (
              <div
                className="rounded-2xl border border-border-subtle bg-surface px-4 py-6 text-center text-sm text-text-muted"
                data-testid="issues-error"
              >
                {error}
              </div>
            ) : (
              <div className="space-y-1.5" data-testid="issues-list">
                {visibleIssues.map((issue) => (
                  <button
                    key={issue.number}
                    data-testid={`issue-${issue.number}`}
                    className="flex w-full items-center gap-3 rounded-[14px] border border-border-subtle bg-surface px-3.5 py-2.5 text-left hover:bg-[var(--color-hover-fill)]"
                    onClick={() => void openDetail(issue.number)}
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
                {visibleIssues.length === 0 && !loading ? (
                  <div
                    className="py-8 text-center text-sm text-text-muted"
                    data-testid="issues-empty"
                  >
                    {/* Native emptyStateMessage priority: search query wins,
                        then active facets, then the plain no-issues copy. */}
                    {search
                      ? `No issues match “${searchQuery.trim()}”.`
                      : filtersActive
                        ? "Try clearing the filters or changing the state."
                        : stateFilter === "all"
                          ? "No issues."
                          : `No ${stateFilter} issues.`}
                  </div>
                ) : null}
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}
