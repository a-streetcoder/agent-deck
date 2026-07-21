import { useEffect, useMemo, useState } from "react";
import { ArrowLeft, X } from "lucide-react";
import { Virtuoso } from "react-virtuoso";
import { cn } from "@/lib/cn";
import { summarizeDiffStats } from "@/lib/changedFilesTree";
import { parseUnifiedDiff, type DiffLine } from "@/lib/unifiedDiff";
import { fetchFileDiff } from "../../state/wsBridge.ts";
import { useAppStore } from "../../state/store.ts";
import { ChangedFilesTree } from "./ChangedFilesTree.tsx";
import { DiffStatLabel, hasNonZeroStat } from "./DiffStatLabel.tsx";
import { OpenInPicker, editorLabel, useOpenInEditor } from "./OpenInPicker.tsx";

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

function DiffLineRow({ line }: { line: DiffLine }) {
  const style = LINE_STYLE[line.kind];
  return (
    <div
      className={cn("flex items-start font-mono text-[11px] leading-[1.5]", style.row)}
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

export function DiffPanel() {
  const open = useAppStore((state) => state.diffPanelOpen);
  const setOpen = useAppStore((state) => state.setDiffPanelOpen);
  const sessionId = useAppStore((state) => state.session?.id ?? null);
  const repo = useAppStore((state) => state.diffRepo);
  const files = useAppStore((state) => state.diffFiles);
  const truncatedSet = useAppStore((state) => state.diffTruncated);

  const [allDirectoriesExpanded, setAllDirectoriesExpanded] = useState(true);
  const [selectedPath, setSelectedPath] = useState<string | null>(null);
  const [fileDiff, setFileDiff] = useState<FileDiffState | null>(null);

  // Slice 11: the server-detected editors + the remembered default. The
  // affordances (file-header picker, tree-row hover action) are hover-revealed
  // so the resting panel layout — and the visual baseline — stay unchanged.
  const editorPicker = useOpenInEditor();

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
    if (!open || selectedPath === null || sessionId === null) return;
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
  }, [open, selectedPath, sessionId, files]);

  // Hidden entirely for non-repo sessions (repo:false) and while closed.
  if (!open || !repo || sessionId === null) return null;

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

  return (
    <aside
      className="flex shrink-0 flex-col overflow-hidden border-l border-border-subtle bg-surface-elevated"
      style={{ width: inDiffView ? "min(42vw, 560px)" : "320px" }}
      data-testid="diff-panel"
    >
      {/* Subheader row (the donor shell's surface-subheader). */}
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
          <button
            type="button"
            className="rounded p-1 text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
            title="Close changes panel"
            aria-label="Close changes panel"
            data-testid="diff-close"
            onClick={() => setOpen(false)}
          >
            <X className="h-3.5 w-3.5" />
          </button>
        </div>
      </div>

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
                style={{ height: "100%" }}
                totalCount={activeDiff.lines.length}
                itemContent={(index) => <DiffLineRow line={activeDiff.lines[index]!} />}
              />
            </div>
          )}
        </div>
      )}
    </aside>
  );
}
