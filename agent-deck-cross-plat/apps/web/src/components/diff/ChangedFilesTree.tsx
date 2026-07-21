import { memo, useCallback, useMemo, useState } from "react";
import { ChevronRight, FileText, Folder, FolderClosed, SquareArrowOutUpRight } from "lucide-react";
import type { DiffFileEntry } from "@agent-deck/contracts";
import { cn } from "@/lib/cn";
import {
  buildChangedFilesTree,
  collectDirectoryPaths,
  type DiffTreeNode,
} from "@/lib/changedFilesTree";
import { DiffStatLabel, hasNonZeroStat } from "./DiffStatLabel";

/**
 * The collapsible changed-files tree (Slice 10), ported from t3code's
 * `chat/ChangedFilesTree.tsx` (MIT) onto our tokens and store-free props: the
 * donor's compacted directory grouping, per-directory aggregate stats,
 * chevron+folder expand/collapse with per-directory overrides keyed against
 * the current tree shape (a changed set resets stale overrides), and per-file
 * rows opening the diff panel. Additions vs the donor: a rename row shows its
 * source path, and binary files label as "binary" instead of a stat. Slice 11
 * adds a hover-revealed open-in-editor action per file row (one click into the
 * remembered editor) — file rows are divs with a button role so the nested
 * action button stays valid HTML.
 */

const EMPTY_DIRECTORY_OVERRIDES: Record<string, boolean> = {};

const STATUS_LABEL: Record<string, string> = {
  A: "added",
  M: "modified",
  D: "deleted",
  R: "renamed",
  C: "copied",
  T: "type changed",
  U: "unmerged",
  "?": "untracked",
};

export const ChangedFilesTree = memo(function ChangedFilesTree(props: {
  files: readonly DiffFileEntry[];
  allDirectoriesExpanded: boolean;
  onOpenFile: (path: string) => void;
  selectedPath?: string | null;
  /** Hover action (Slice 11): open this file in the remembered editor. */
  onOpenInEditor?: (path: string) => void;
  /** Tooltip/aria label for the hover action (names the remembered editor). */
  openInEditorLabel?: string;
}) {
  const {
    files,
    allDirectoriesExpanded,
    onOpenFile,
    selectedPath = null,
    onOpenInEditor,
    openInEditorLabel = "Open in editor",
  } = props;
  const treeNodes = useMemo(() => buildChangedFilesTree(files), [files]);
  const directoryPathsKey = useMemo(() => collectDirectoryPaths(treeNodes).join("\0"), [treeNodes]);
  const hasDirectoryNodes = directoryPathsKey.length > 0;
  const expansionStateKey = `${allDirectoriesExpanded ? "expanded" : "collapsed"}\0${directoryPathsKey}`;
  const [directoryExpansionState, setDirectoryExpansionState] = useState<{
    key: string;
    overrides: Record<string, boolean>;
  }>(() => ({ key: expansionStateKey, overrides: {} }));
  const expandedDirectories =
    directoryExpansionState.key === expansionStateKey
      ? directoryExpansionState.overrides
      : EMPTY_DIRECTORY_OVERRIDES;

  const toggleDirectory = useCallback(
    (pathValue: string) => {
      setDirectoryExpansionState((current) => {
        const nextOverrides = current.key === expansionStateKey ? current.overrides : {};
        return {
          key: expansionStateKey,
          overrides: {
            ...nextOverrides,
            [pathValue]: !(nextOverrides[pathValue] ?? allDirectoriesExpanded),
          },
        };
      });
    },
    [allDirectoriesExpanded, expansionStateKey],
  );

  const renderTreeNode = (node: DiffTreeNode, depth: number) => {
    const leftPadding = 8 + depth * 14;
    if (node.kind === "directory") {
      const isExpanded = expandedDirectories[node.path] ?? allDirectoriesExpanded;
      return (
        <div key={`dir:${node.path}`}>
          <button
            type="button"
            className="group flex w-full items-center gap-1.5 rounded-md py-1 pr-2 text-left transition-colors hover:bg-[var(--color-hover-fill)]"
            style={{ paddingLeft: `${leftPadding}px` }}
            data-testid="diff-tree-dir"
            data-path={node.path}
            aria-expanded={isExpanded}
            onClick={() => toggleDirectory(node.path)}
          >
            <ChevronRight
              aria-hidden="true"
              className={cn(
                "h-3.5 w-3.5 shrink-0 text-text-muted transition-transform group-hover:text-text-secondary",
                isExpanded && "rotate-90",
              )}
            />
            {isExpanded ? (
              <Folder className="h-3.5 w-3.5 shrink-0 text-text-muted" />
            ) : (
              <FolderClosed className="h-3.5 w-3.5 shrink-0 text-text-muted" />
            )}
            <span className="truncate font-mono text-[11px] text-text-secondary group-hover:text-text-primary">
              {node.name}
            </span>
            {hasNonZeroStat(node.stat) && (
              <span className="ml-auto shrink-0 font-mono text-[10px] tabular-nums">
                <DiffStatLabel additions={node.stat.additions} deletions={node.stat.deletions} />
              </span>
            )}
          </button>
          {isExpanded && (
            <div className="space-y-0.5">
              {node.children.map((childNode) => renderTreeNode(childNode, depth + 1))}
            </div>
          )}
        </div>
      );
    }

    const { entry } = node;
    const statusLabel = STATUS_LABEL[entry.status];
    return (
      <div
        key={`file:${node.path}`}
        role="button"
        tabIndex={0}
        className={cn(
          "group flex w-full cursor-pointer items-center gap-1.5 rounded-md py-1 pr-2 text-left transition-colors hover:bg-[var(--color-hover-fill)]",
          selectedPath === node.path && "bg-[var(--color-selection-fill)]",
        )}
        style={{ paddingLeft: `${leftPadding}px` }}
        data-testid="diff-tree-file"
        data-path={node.path}
        data-status={entry.status}
        title={statusLabel ? `${node.path} (${statusLabel})` : node.path}
        onClick={() => onOpenFile(node.path)}
        onKeyDown={(event) => {
          // Only when the ROW itself is focused: Enter/Space on the nested
          // open-in-editor button bubbles here, and preventDefault would
          // cancel the button's own activation (keyboard users would get the
          // diff view instead of the editor).
          if (event.target !== event.currentTarget) return;
          if (event.key === "Enter" || event.key === " ") {
            event.preventDefault();
            onOpenFile(node.path);
          }
        }}
      >
        {hasDirectoryNodes || depth > 0 ? (
          <span aria-hidden="true" className="h-3.5 w-3.5 shrink-0" />
        ) : null}
        <FileText className="h-3.5 w-3.5 shrink-0 text-text-muted" />
        <span className="min-w-0 truncate font-mono text-[11px] text-text-secondary group-hover:text-text-primary">
          {node.name}
          {entry.oldPath !== undefined && (
            <span className="text-text-muted"> ← {entry.oldPath}</span>
          )}
        </span>
        {/* Right cluster: the hover-revealed open action (hidden at rest, so
            the resting row layout is unchanged) + the stat label. */}
        <span className="ml-auto flex shrink-0 items-center gap-1">
          {onOpenInEditor && (
            <button
              type="button"
              className="hidden shrink-0 rounded p-0.5 text-text-muted hover:text-text-primary group-focus-within:flex group-hover:flex"
              title={openInEditorLabel}
              aria-label={openInEditorLabel}
              data-testid="diff-tree-open"
              onClick={(event) => {
                event.stopPropagation();
                onOpenInEditor(node.path);
              }}
            >
              <SquareArrowOutUpRight aria-hidden="true" className="h-3 w-3" />
            </button>
          )}
          <span className="shrink-0 font-mono text-[10px] tabular-nums">
            {entry.binary ? (
              <span className="text-text-muted">binary</span>
            ) : node.stat ? (
              <DiffStatLabel additions={node.stat.additions} deletions={node.stat.deletions} />
            ) : null}
          </span>
        </span>
      </div>
    );
  };

  return (
    <div className="space-y-0.5" data-testid="diff-tree">
      {treeNodes.map((node) => renderTreeNode(node, 0))}
    </div>
  );
});
