import { useEffect, useMemo, useRef, useState } from "react";
import { ArrowLeft, ArrowRight, MessageSquarePlus, Pencil, Trash2 } from "lucide-react";
import { Virtuoso, type VirtuosoHandle } from "react-virtuoso";
import { cn } from "@/lib/cn";
import { summarizeDiffStats } from "@/lib/changedFilesTree";
import { parseUnifiedDiff, type DiffLine } from "@/lib/unifiedDiff";
import {
  buildLineReviewComment,
  findAnchoredLineIndex,
  isCommentableLine,
  type PendingReviewComment,
} from "@/lib/reviewComments";
import { fetchFileDiff, mergeWorktreeSession } from "../../state/wsBridge.ts";
import { useAppStore } from "../../state/store.ts";
import { ChangedFilesTree } from "./ChangedFilesTree.tsx";
import { DiffStatLabel, hasNonZeroStat } from "./DiffStatLabel.tsx";
import { OpenInPicker, editorLabel, useOpenInEditor } from "./OpenInPicker.tsx";

/** Monotonic ids for pending review comments (never rendered — anchor is
 * side+line — so a plain counter is enough and avoids secure-context reliance
 * on crypto.randomUUID). */
let reviewCommentSeq = 0;
function nextReviewCommentId(): string {
  reviewCommentSeq += 1;
  return `review-${reviewCommentSeq}`;
}

/** Which diff row (if any) has its inline comment editor open, and whether it is
 * adding a fresh comment or editing an existing one. */
interface CommentBoxState {
  rowIndex: number;
  mode: "add" | "edit";
  commentId?: string;
  initialText: string;
}

/** Stable empty reference so the selector never returns a fresh array. */
const EMPTY_COMMENTS: readonly PendingReviewComment[] = [];

/**
 * The changed-files / diff panel (Slice 10): a right-hand aside on the chat
 * surface, pattern-ported from t3code's `DiffPanel.tsx` + `DiffPanelShell.tsx`
 * (MIT) and condensed to our surface — working-tree scope only (their
 * turn/branch scope pickers arrive with checkpoints/worktree slices), unified
 * view only (split view is deferred to the review-comments slice), our zustand
 * store instead of atoms. What survives the port: the shell's fixed-width
 * aside with a subheader row, the changed-files tree with per-file stats
 * opening a file's diff, and the donor's empty/binary/truncated states.
 *
 * Diff rendering happens ON the main thread, virtualized — see
 * `lib/unifiedDiff.ts` for the worker-vs-main rationale (the donor's worker
 * pool exists for shiki highlighting we don't do; our patches are bounded by
 * DIFF_MAX_PATCH_CHARS and rows are virtualized with react-virtuoso, so a
 * max-size patch parses in a few ms and scrolls at viewport-DOM cost).
 *
 * Live updates: the store's changed-file set is refreshed by `diff_push` at
 * turn boundaries and refetched on (re)subscribe (wsBridge). The open file's
 * patch refetches whenever the set changes; a file that vanished from the set
 * drops back to the tree.
 */

interface FileDiffState {
  /**
   * The file (and session) this state was fetched for. Render + the
   * keep-stale-while-revalidate branch both check the tag: a stale patch stays
   * visible only while refreshing the SAME file in the SAME session (diff_push
   * refresh); switching files or sessions shows the loading state instead of
   * the previous file's hunks under the new header.
   */
  path: string;
  sessionId: string;
  status: "loading" | "loaded" | "error";
  lines: DiffLine[];
  truncated: boolean;
  binary: boolean;
  empty: boolean;
  error?: string;
}

const LINE_STYLE: Record<DiffLine["kind"], { row?: string; text?: string }> = {
  add: {
    row: "bg-[color-mix(in_srgb,var(--color-diff-added)_14%,transparent)]",
    text: "text-[var(--color-diff-added)]",
  },
  del: {
    row: "bg-[color-mix(in_srgb,var(--color-diff-removed)_14%,transparent)]",
    text: "text-[var(--color-diff-removed)]",
  },
  hunk: {
    row: "bg-[var(--color-hover-fill)]",
    text: "text-accent",
  },
  meta: { text: "text-text-muted" },
  context: { text: "text-text-secondary" },
};

/** The inline comment editor rendered beneath a diff row (Slice 12). */
function InlineCommentEditor(props: {
  initialText: string;
  mode: "add" | "edit";
  onSubmit: (text: string) => void;
  onCancel: () => void;
}) {
  const [text, setText] = useState(props.initialText);
  const ref = useRef<HTMLTextAreaElement>(null);
  useEffect(() => {
    ref.current?.focus();
  }, []);
  return (
    <div
      className="border-y border-border-subtle bg-surface-elevated px-3 py-2"
      data-testid="diff-comment-box"
    >
      <textarea
        ref={ref}
        data-testid="diff-comment-input"
        className="block max-h-40 min-h-[3.5rem] w-full resize-y rounded-md border border-border-strong bg-surface px-2 py-1.5 text-xs text-text-primary outline-none placeholder:text-text-muted focus:border-accent"
        placeholder="Leave a comment on this line…"
        value={text}
        onChange={(event) => setText(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === "Escape") {
            event.preventDefault();
            props.onCancel();
            return;
          }
          if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
            event.preventDefault();
            if (text.trim().length > 0) props.onSubmit(text);
          }
        }}
      />
      <div className="mt-1.5 flex items-center justify-end gap-1.5">
        <button
          type="button"
          data-testid="diff-comment-cancel"
          className="rounded-md px-2 py-1 text-[11px] text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
          onClick={props.onCancel}
        >
          Cancel
        </button>
        <button
          type="button"
          data-testid="diff-comment-save"
          disabled={text.trim().length === 0}
          className="rounded-md bg-accent px-2.5 py-1 text-[11px] font-medium text-[var(--color-accent-foreground)] transition-opacity hover:opacity-90 disabled:opacity-40"
          onClick={() => props.onSubmit(text)}
        >
          {props.mode === "edit" ? "Save" : "Comment"}
        </button>
      </div>
    </div>
  );
}

/** A committed pending comment shown inline under its anchored row. */
function InlineCommentCard(props: {
  comment: PendingReviewComment;
  onEdit: () => void;
  onRemove: () => void;
}) {
  return (
    <div
      className="flex items-start gap-2 border-y border-border-subtle bg-[color-mix(in_srgb,var(--color-accent)_7%,var(--color-surface-elevated))] px-3 py-1.5"
      data-testid="diff-inline-comment"
    >
      <span className="min-w-0 flex-1 whitespace-pre-wrap break-words text-[11px] leading-snug text-text-secondary">
        {props.comment.text}
      </span>
      <div className="flex shrink-0 items-center gap-0.5">
        <button
          type="button"
          data-testid="diff-inline-comment-edit"
          className="rounded p-0.5 text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
          title="Edit comment"
          aria-label="Edit comment"
          onClick={props.onEdit}
        >
          <Pencil className="h-3 w-3" aria-hidden />
        </button>
        <button
          type="button"
          data-testid="diff-inline-comment-remove"
          className="rounded p-0.5 text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-[var(--color-role-error)]"
          title="Delete comment"
          aria-label="Delete comment"
          onClick={props.onRemove}
        >
          <Trash2 className="h-3 w-3" aria-hidden />
        </button>
      </div>
    </div>
  );
}

function DiffLineRow(props: {
  line: DiffLine;
  commentable: boolean;
  comments: readonly PendingReviewComment[];
  boxOpen: boolean;
  boxMode: "add" | "edit" | undefined;
  boxCommentId: string | undefined;
  boxInitialText: string;
  onAddComment: () => void;
  onEditComment: (comment: PendingReviewComment) => void;
  onRemoveComment: (commentId: string) => void;
  onSubmit: (text: string) => void;
  onCancel: () => void;
}) {
  const { line } = props;
  const style = LINE_STYLE[line.kind];
  return (
    <div>
      <div
        className={cn(
          "group/diffrow flex items-start font-mono text-[11px] leading-[1.5]",
          style.row,
        )}
        data-testid="diff-line"
        data-kind={line.kind}
      >
        <span className="w-9 shrink-0 select-none pr-1 text-right tabular-nums text-text-muted/70 text-[10px] leading-[1.65]">
          {line.oldLine ?? ""}
        </span>
        <span className="w-9 shrink-0 select-none pr-2 text-right tabular-nums text-text-muted/70 text-[10px] leading-[1.65]">
          {line.newLine ?? ""}
        </span>
        <span className={cn("min-w-0 flex-1 whitespace-pre-wrap break-all pr-2", style.text)}>
          {line.text.length > 0 ? line.text : " "}
        </span>
        {/* Hover-revealed add-comment affordance (hidden at rest so the resting
            panel layout — and the diff-panel visual baseline — is unchanged). */}
        {props.commentable && !props.boxOpen && (
          <button
            type="button"
            data-testid="diff-comment-add"
            className="mr-1 hidden shrink-0 rounded p-0.5 text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-accent group-focus-within/diffrow:flex group-hover/diffrow:flex"
            title="Comment on this line"
            aria-label="Comment on this line"
            onClick={props.onAddComment}
          >
            <MessageSquarePlus className="h-3.5 w-3.5" aria-hidden />
          </button>
        )}
      </div>
      {props.comments.map((comment) =>
        props.boxOpen && props.boxMode === "edit" && props.boxCommentId === comment.id ? null : (
          <InlineCommentCard
            key={comment.id}
            comment={comment}
            onEdit={() => props.onEditComment(comment)}
            onRemove={() => props.onRemoveComment(comment.id)}
          />
        ),
      )}
      {props.boxOpen && props.boxMode !== undefined && (
        <InlineCommentEditor
          key={`${props.boxMode}:${props.boxCommentId ?? "new"}`}
          initialText={props.boxInitialText}
          mode={props.boxMode}
          onSubmit={props.onSubmit}
          onCancel={props.onCancel}
        />
      )}
    </div>
  );
}

function NoticeBar({ children }: { children: string }) {
  return (
    <p
      className="shrink-0 border-b border-border-subtle bg-[var(--color-hover-fill)] px-3 py-1.5 text-[11px] text-text-muted"
      data-testid="diff-notice"
    >
      {children}
    </p>
  );
}

function CenteredState({ children, testId }: { children: string; testId: string }) {
  return (
    <div
      className="flex flex-1 items-center justify-center px-5 text-center text-xs text-text-muted"
      data-testid={testId}
    >
      {children}
    </div>
  );
}

/**
 * Slice 20 branch toolbar: for a session running in an isolated worktree, the
 * diff panel IS the review surface — its working-tree-vs-HEAD diff (Slice 9) is
 * the full uncommitted branch delta, because worktree work stays uncommitted
 * until merge. So the panel hosts the first-class review-then-merge affordance:
 * the `worktreeBranch → sourceBranch` line plus a primary Merge button. The
 * changed-FILE count already in the subheader is the "ready to merge" signal;
 * there is deliberately no commits-ahead count (the work is uncommitted
 * pre-merge, so gitCommitsAhead is 0 until the merge route commits it).
 */
function WorktreeMergeToolbar(props: {
  sessionId: string;
  worktreeBranch: string;
  worktreeSourceBranch: string;
}) {
  const pushToast = useAppStore((state) => state.pushToast);
  const setError = useAppStore((state) => state.setError);
  // Idle-gate the merge (same rule as the checkpoints panel's Restore): merging
  // while a turn is still writing to the worktree would auto-commit a
  // half-written tree. Disabled while a turn runs.
  const running = useAppStore((state) => state.transcript.agentStatus === "running");
  const [merging, setMerging] = useState(false);

  const merge = async (): Promise<void> => {
    setMerging(true);
    setError(null);
    try {
      const { sourceBranch, commits } = await mergeWorktreeSession(props.sessionId);
      // mergeWorktreeSession refreshes the (now-empty) changed-file set for us —
      // the working-tree diff clears once the work is committed + merged.
      pushToast({
        kind: "success",
        message: `Merged ${commits} commit${commits === 1 ? "" : "s"} into ${sourceBranch}`,
      });
    } catch (error) {
      // 400 "Nothing to merge" and 409 "Merge failed: <conflict>" both arrive as
      // the thrown Error's message — surface it verbatim.
      setError(error instanceof Error ? error.message : String(error));
    } finally {
      setMerging(false);
    }
  };

  return (
    <div
      className="flex items-center justify-between gap-2 border-b border-border-subtle bg-surface px-3 py-2"
      data-testid="diff-worktree-toolbar"
    >
      <div className="flex min-w-0 items-center gap-1.5 font-mono text-[11px] text-text-secondary">
        <span
          className="truncate text-text-primary"
          title={props.worktreeBranch}
          data-testid="diff-worktree-branch"
        >
          {props.worktreeBranch}
        </span>
        <ArrowRight className="h-3 w-3 shrink-0 text-text-muted" aria-hidden />
        <span className="shrink-0 text-text-primary">{props.worktreeSourceBranch}</span>
      </div>
      <button
        type="button"
        data-testid="diff-merge"
        className="shrink-0 rounded-capsule px-3 py-1 text-[11px] font-medium shadow-capsule disabled:opacity-40"
        style={{
          background:
            "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
          color: "var(--color-accent-foreground)",
        }}
        disabled={merging || running}
        title={running ? "Wait for the current turn to finish" : undefined}
        onClick={() => void merge()}
      >
        {merging ? "Merging…" : `Merge to ${props.worktreeSourceBranch}`}
      </button>
    </div>
  );
}

export function DiffPanel() {
  const sessionId = useAppStore((state) => state.session?.id ?? null);
  const repo = useAppStore((state) => state.diffRepo);
  const files = useAppStore((state) => state.diffFiles);
  const truncatedSet = useAppStore((state) => state.diffTruncated);

  // Slice 20: a worktree session is identified by the presence of these meta
  // fields (there is no isWorktree boolean). When set, the panel shows the
  // branch → source toolbar with the primary Merge action.
  const worktreeBranch = useAppStore((state) => state.session?.worktreeBranch ?? null);
  const worktreeSourceBranch = useAppStore((state) => state.session?.worktreeSourceBranch ?? null);
  // The gitAutomation setting gates the Merge toolbar, matching the Git screen's
  // Merge banner (one consistent merge gate). `null` until it loads so the
  // toolbar never flashes before the gate is known. Read once on mount (the
  // setting doesn't change within a run without a Preferences round-trip).
  const [gitAutomation, setGitAutomation] = useState<boolean | null>(null);
  useEffect(() => {
    void fetch("/settings")
      .then((response) => response.json())
      .then((data: { settings: { gitAutomation: boolean } }) =>
        setGitAutomation(data.settings.gitAutomation),
      )
      .catch(() => {});
  }, []);

  const [allDirectoriesExpanded, setAllDirectoriesExpanded] = useState(true);
  const [selectedPath, setSelectedPath] = useState<string | null>(null);
  const [fileDiff, setFileDiff] = useState<FileDiffState | null>(null);

  // Slice 11: the server-detected editors + the remembered default. The
  // affordances (file-header picker, tree-row hover action) are hover-revealed
  // so the resting panel layout — and the visual baseline — stay unchanged.
  const editorPicker = useOpenInEditor();

  // Slice 12: review comments for the current session + the jump-to-diff
  // request a pending composer card raises. The panel is the capture surface
  // (add/edit/delete inline on rows) and the jump target.
  const pendingComments = useAppStore((state) =>
    sessionId ? (state.pendingReviewComments[sessionId] ?? EMPTY_COMMENTS) : EMPTY_COMMENTS,
  );
  const addReviewComment = useAppStore((state) => state.addReviewComment);
  const updateReviewComment = useAppStore((state) => state.updateReviewComment);
  const removeReviewComment = useAppStore((state) => state.removeReviewComment);
  const diffJumpRequest = useAppStore((state) => state.diffJumpRequest);
  const clearDiffJump = useAppStore((state) => state.clearDiffJump);
  const virtuosoRef = useRef<VirtuosoHandle>(null);
  const [commentBox, setCommentBox] = useState<CommentBoxState | null>(null);

  // A jump request naming a different file selects it first; the scroll happens
  // once that file's patch has loaded (the effect below). A request whose file
  // has left the changed set (reverted/committed while its composer card stayed
  // clickable) is DROPPED, not selected: selecting a path the guard effect
  // below immediately nulls out would ping-pong gone.txt -> null -> gone.txt
  // forever ("Maximum update depth exceeded"), since the scroll effect that
  // normally clears the request never fires for a file whose fetch is aborted.
  useEffect(() => {
    if (diffJumpRequest === null) return;
    if (!files.some((file) => file.path === diffJumpRequest.path)) {
      clearDiffJump();
      return;
    }
    if (diffJumpRequest.path !== selectedPath) {
      setSelectedPath(diffJumpRequest.path);
    }
  }, [diffJumpRequest, selectedPath, files, clearDiffJump]);

  // Scroll to the anchored row once the requested file's patch is loaded, then
  // drop the request. Matched by side+line (never a stale index) so an edit
  // above the anchor doesn't misdirect the jump; a vanished line just no-ops.
  useEffect(() => {
    if (
      diffJumpRequest === null ||
      diffJumpRequest.path !== selectedPath ||
      fileDiff === null ||
      fileDiff.status !== "loaded" ||
      fileDiff.path !== selectedPath
    ) {
      return;
    }
    const index = findAnchoredLineIndex(fileDiff.lines, diffJumpRequest);
    if (index >= 0) {
      virtuosoRef.current?.scrollToIndex({ index, align: "center" });
    }
    clearDiffJump();
  }, [diffJumpRequest, selectedPath, fileDiff, clearDiffJump]);

  // A closed editor whose row no longer exists (file switched) is dropped; an
  // OPEN editor is also dropped when the same file's patch refreshes (diff_push
  // rebuilds `fileDiff.lines`). The box anchors by captured rowIndex, so a
  // survivor would silently re-anchor to — and serialize the excerpt of —
  // whatever content now sits at that index (e.g. a hunk that landed above),
  // with no staleness signal. Closing it is the honest signal.
  useEffect(() => {
    setCommentBox(null);
  }, [selectedPath, sessionId, fileDiff]);

  const summaryStat = useMemo(() => summarizeDiffStats(files), [files]);
  const selectedEntry = selectedPath
    ? (files.find((file) => file.path === selectedPath) ?? null)
    : null;

  // A file that left the changed set (or a session switch that emptied it)
  // drops the selection back to the tree.
  useEffect(() => {
    if (selectedPath !== null && !files.some((file) => file.path === selectedPath)) {
      setSelectedPath(null);
      setFileDiff(null);
    }
  }, [files, selectedPath]);

  // Fetch (and refetch after every diff_push — `files` identity changes) the
  // selected file's bounded unified diff.
  useEffect(() => {
    if (selectedPath === null || sessionId === null) return;
    let stale = false;
    setFileDiff((current) =>
      current &&
      current.status === "loaded" &&
      current.path === selectedPath &&
      current.sessionId === sessionId
        ? current // keep the old patch visible while the same file's refresh is in flight
        : {
            path: selectedPath,
            sessionId,
            status: "loading",
            lines: [],
            truncated: false,
            binary: false,
            empty: false,
          },
    );
    void fetchFileDiff(selectedPath)
      .then((result) => {
        if (stale || result === null) return;
        setFileDiff({
          path: selectedPath,
          sessionId,
          status: "loaded",
          lines: parseUnifiedDiff(result.diff),
          truncated: result.truncated,
          binary: result.binary,
          empty: result.diff.trim().length === 0,
        });
      })
      .catch((error: unknown) => {
        if (stale) return;
        setFileDiff({
          path: selectedPath,
          sessionId,
          status: "error",
          lines: [],
          truncated: false,
          binary: false,
          empty: false,
          error: String(error),
        });
      });
    return () => {
      stale = true;
    };
  }, [selectedPath, sessionId, files]);

  if (sessionId === null) return null;
  // The tab only opens for a git repo (the diffRepo gate lives on the header /
  // "+" entry), so `!repo` here is almost always the brief window right after a
  // session switch, before the first diff_files fetch re-confirms the repo. Show
  // a muted placeholder rather than a blank tab body during that window.
  if (!repo) {
    return (
      <div
        className="flex min-h-0 flex-1 items-center justify-center px-4 text-center text-xs text-text-muted"
        data-testid="diff-panel-pending"
      >
        No changes to show.
      </div>
    );
  }

  const inDiffView = selectedPath !== null;
  // Only a diff fetched for the currently selected file (in the current
  // session) may render; a mismatched tag draws as loading until the fetch
  // effect replaces it. Guards the frame(s) between a tree click / session
  // switch and the effect run, plus the in-flight window after it.
  const activeDiff =
    fileDiff !== null && fileDiff.path === selectedPath && fileDiff.sessionId === sessionId
      ? fileDiff
      : null;

  // The line the header's Open jumps to: the first changed line of the loaded
  // patch (its new-side number; a pure deletion falls back to the old side).
  const firstChanged =
    activeDiff !== null && activeDiff.status === "loaded"
      ? activeDiff.lines.find((line) => line.kind === "add" || line.kind === "del")
      : undefined;
  const openAtLine = firstChanged?.newLine ?? firstChanged?.oldLine ?? undefined;

  // Pending comments anchored to the OPEN file, mapped to their rendered row
  // (by side+line — the same rule the composer-card jump uses). Comments whose
  // line no longer exists in the refreshed patch simply don't anchor (they
  // still ride the composer).
  const commentsForFile =
    selectedPath !== null
      ? pendingComments.filter((comment) => comment.filePath === selectedPath)
      : EMPTY_COMMENTS;
  const commentsByRow = new Map<number, PendingReviewComment[]>();
  if (activeDiff !== null && activeDiff.status === "loaded") {
    for (const comment of commentsForFile) {
      const index = findAnchoredLineIndex(activeDiff.lines, comment);
      if (index < 0) continue;
      const bucket = commentsByRow.get(index);
      if (bucket) bucket.push(comment);
      else commentsByRow.set(index, [comment]);
    }
  }

  const submitComment = (rowIndex: number, text: string): void => {
    const trimmed = text.trim();
    if (commentBox?.mode === "edit" && commentBox.commentId !== undefined) {
      if (trimmed.length > 0) updateReviewComment(sessionId, commentBox.commentId, trimmed);
      setCommentBox(null);
      return;
    }
    if (trimmed.length === 0 || activeDiff === null || selectedPath === null) {
      setCommentBox(null);
      return;
    }
    const comment = buildLineReviewComment({
      id: nextReviewCommentId(),
      filePath: selectedPath,
      lines: activeDiff.lines,
      lineIndex: rowIndex,
      text: trimmed,
    });
    if (comment !== null) addReviewComment(sessionId, comment);
    setCommentBox(null);
  };

  return (
    <div className="flex min-h-0 flex-1 flex-col overflow-hidden" data-testid="diff-panel">
      {/* Subheader row (the donor shell's surface-subheader). The tool title +
          count + secondary controls stay; the close X moved to the tab. */}
      <div className="flex items-center justify-between gap-2 border-b border-border-subtle px-3 py-2">
        <div className="flex min-w-0 items-center gap-2">
          <span
            className="text-xs font-semibold uppercase tracking-wide text-text-muted"
            style={{ fontStretch: "expanded" }}
          >
            Changes
          </span>
          <span className="text-xs tabular-nums text-text-muted" data-testid="diff-file-count">
            {files.length}
          </span>
          {hasNonZeroStat(summaryStat) && (
            <DiffStatLabel
              additions={summaryStat.additions}
              deletions={summaryStat.deletions}
              className="text-[11px]"
              layout="inline"
            />
          )}
        </div>
        <div className="flex shrink-0 items-center gap-1">
          {files.length > 0 && (
            <button
              type="button"
              className="rounded px-1.5 py-0.5 text-[11px] text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
              data-testid="diff-toggle-dirs"
              onClick={() => setAllDirectoriesExpanded((expanded) => !expanded)}
            >
              {allDirectoriesExpanded ? "Collapse all" : "Expand all"}
            </button>
          )}
        </div>
      </div>

      {gitAutomation === true && worktreeBranch !== null && worktreeSourceBranch !== null && (
        <WorktreeMergeToolbar
          sessionId={sessionId}
          worktreeBranch={worktreeBranch}
          worktreeSourceBranch={worktreeSourceBranch}
        />
      )}

      {truncatedSet && (
        <NoticeBar>The changed-file list was truncated at the server limit.</NoticeBar>
      )}

      {files.length === 0 ? (
        <CenteredState testId="diff-empty">No changes in the working tree.</CenteredState>
      ) : (
        <div
          className={cn(
            "overflow-y-auto px-1.5 py-1.5",
            // Tree-only: fill the panel. With a file open: the tree keeps a
            // capped strip on top and the diff takes the remainder below
            // (the donor's ChangedFilesCard → DiffPanel pairing, stacked).
            inDiffView ? "max-h-[38%] shrink-0 border-b border-border-subtle" : "min-h-0 flex-1",
          )}
        >
          <ChangedFilesTree
            files={files}
            allDirectoriesExpanded={allDirectoriesExpanded}
            onOpenFile={setSelectedPath}
            selectedPath={selectedPath}
            {...(editorPicker.available.length > 0 && editorPicker.preferred !== null
              ? {
                  openInEditorLabel: `Open in ${editorLabel(editorPicker.preferred)}`,
                  onOpenInEditor: (path: string) => editorPicker.open(path, undefined),
                }
              : {})}
          />
        </div>
      )}

      {inDiffView && (
        <div className="flex min-h-0 flex-1 flex-col" data-testid="diff-file-view">
          {/* File header: path + its stat label + open-in-editor + close-file.
              The picker reveals on header hover/focus so the resting layout
              (and the diff-panel visual baseline) is unchanged. */}
          <div className="group/fileheader flex items-center gap-2 border-b border-border-subtle bg-surface px-3 py-1.5">
            <span
              className="min-w-0 truncate font-mono text-[11px] text-text-primary"
              data-testid="diff-file-path"
              title={selectedPath}
            >
              {selectedEntry?.oldPath !== undefined ? `${selectedEntry.oldPath} → ` : ""}
              {selectedPath}
            </span>
            {selectedEntry && !selectedEntry.binary && selectedEntry.insertions !== null && (
              <span className="ml-auto shrink-0 font-mono text-[10px] tabular-nums">
                <DiffStatLabel
                  additions={selectedEntry.insertions}
                  deletions={selectedEntry.deletions ?? 0}
                />
              </span>
            )}
            <OpenInPicker
              available={editorPicker.available}
              preferred={editorPicker.preferred}
              className="hidden group-focus-within/fileheader:flex group-hover/fileheader:flex"
              onOpen={(editor) => {
                if (selectedPath !== null) editorPicker.open(selectedPath, openAtLine, editor);
              }}
            />
            <button
              type="button"
              className={cn(
                "shrink-0 rounded p-0.5 text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary",
                !(selectedEntry && !selectedEntry.binary && selectedEntry.insertions !== null) &&
                  "ml-auto",
              )}
              title="Back to changed files"
              aria-label="Back to changed files"
              data-testid="diff-back"
              onClick={() => {
                setSelectedPath(null);
                setFileDiff(null);
              }}
            >
              <ArrowLeft className="h-3.5 w-3.5" />
            </button>
          </div>
          {activeDiff?.truncated && (
            <NoticeBar>
              This diff was truncated because it exceeded the preview limit. The changes shown are
              incomplete.
            </NoticeBar>
          )}
          {activeDiff === null || activeDiff.status === "loading" ? (
            <CenteredState testId="diff-loading">Loading diff…</CenteredState>
          ) : activeDiff.status === "error" ? (
            <CenteredState testId="diff-error">
              {`Couldn't load this diff: ${activeDiff.error ?? "unknown error"}`}
            </CenteredState>
          ) : activeDiff.binary || selectedEntry?.binary ? (
            <CenteredState testId="diff-binary">
              Binary file — no textual diff to show.
            </CenteredState>
          ) : activeDiff.empty ? (
            <CenteredState testId="diff-no-changes">
              No net changes in this selection.
            </CenteredState>
          ) : (
            /* `relative` is load-bearing: Virtuoso positions its viewport
               measurement div absolutely, and without a positioned wrapper it
               would anchor to the chat layer and swallow clicks panel-wide. */
            <div className="relative min-h-0 flex-1" data-testid="diff-lines">
              <Virtuoso
                ref={virtuosoRef}
                style={{ height: "100%" }}
                totalCount={activeDiff.lines.length}
                itemContent={(index) => {
                  const line = activeDiff.lines[index]!;
                  const rowComments = commentsByRow.get(index) ?? EMPTY_COMMENTS;
                  const boxOpen = commentBox?.rowIndex === index;
                  return (
                    <DiffLineRow
                      line={line}
                      commentable={isCommentableLine(line)}
                      comments={rowComments}
                      boxOpen={boxOpen}
                      boxMode={boxOpen ? commentBox?.mode : undefined}
                      boxCommentId={boxOpen ? commentBox?.commentId : undefined}
                      boxInitialText={boxOpen ? (commentBox?.initialText ?? "") : ""}
                      onAddComment={() =>
                        setCommentBox({ rowIndex: index, mode: "add", initialText: "" })
                      }
                      onEditComment={(comment) =>
                        setCommentBox({
                          rowIndex: index,
                          mode: "edit",
                          commentId: comment.id,
                          initialText: comment.text,
                        })
                      }
                      onRemoveComment={(commentId) => removeReviewComment(sessionId, commentId)}
                      onSubmit={(text) => submitComment(index, text)}
                      onCancel={() => setCommentBox(null)}
                    />
                  );
                }}
              />
            </div>
          )}
        </div>
      )}
    </div>
  );
}
