import type { ReactNode } from "react";
import { ChevronRight, FileText, Folder, FolderClosed, SquareArrowOutUpRight } from "lucide-react";
import { cn } from "@/lib/cn";
import type { FileTreeController } from "./useFileTree.ts";

/**
 * The lazy file-navigation tree (Slice 13b) — the read view over
 * {@link FileTreeController}. Ported in SPIRIT from t3code's file browser
 * (chevron+folder expand/collapse, directories-first rows, per-file open) but
 * rebuilt on our transport: the donor renders a whole-tree index via
 * `@pierre/trees`; we expand one directory at a time (a click on an unloaded
 * directory triggers its `file_list`), reusing the changed-files-tree row
 * idioms (indent-by-depth, hover-revealed open-in-editor action) so the two
 * trees read as one family.
 */

/** Human-readable file size (kB/MB with one decimal past 1 kB). */
function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} kB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export function FileTree(props: {
  controller: FileTreeController;
  onOpenFile: (path: string) => void;
  selectedPath: string | null;
  /** Hover action: open this file in the remembered editor (optional). */
  onOpenInEditor?: (path: string) => void;
  /** Tooltip/aria label for the hover action (names the remembered editor). */
  openInEditorLabel?: string;
}) {
  const {
    controller,
    onOpenFile,
    selectedPath,
    onOpenInEditor,
    openInEditorLabel = "Open in editor",
  } = props;
  const { dirs, expanded, toggleDir } = controller;

  const renderEntries = (dirPath: string, depth: number): ReactNode => {
    const state = dirs.get(dirPath);
    const leftPadding = 8 + depth * 14;
    if (state === undefined || (state.status === "loading" && state.entries.length === 0)) {
      return (
        <div
          className="py-1 font-mono text-[11px] text-text-muted"
          style={{ paddingLeft: `${leftPadding + 20}px` }}
          data-testid="file-tree-loading"
        >
          Loading…
        </div>
      );
    }
    if (state.status === "error" && state.entries.length === 0) {
      return (
        <div
          className="py-1 font-mono text-[11px] text-[var(--color-role-error)]"
          style={{ paddingLeft: `${leftPadding + 20}px` }}
          data-testid="file-tree-error"
        >
          {state.error ?? "Couldn't list this directory."}
        </div>
      );
    }
    if (state.entries.length === 0) {
      return (
        <div
          className="py-1 font-mono text-[11px] text-text-muted"
          style={{ paddingLeft: `${leftPadding + 20}px` }}
        >
          Empty
        </div>
      );
    }

    return (
      <>
        {state.entries.map((entry) => {
          const path = dirPath ? `${dirPath}/${entry.name}` : entry.name;
          if (entry.kind === "dir") {
            const isExpanded = expanded.has(path);
            return (
              <div key={`dir:${path}`}>
                <button
                  type="button"
                  className="group flex w-full items-center gap-1.5 rounded-md py-1 pr-2 text-left transition-colors hover:bg-[var(--color-hover-fill)]"
                  style={{ paddingLeft: `${leftPadding}px` }}
                  data-testid="file-tree-dir"
                  data-path={path}
                  aria-expanded={isExpanded}
                  onClick={() => toggleDir(path)}
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
                    {entry.name}
                  </span>
                </button>
                {isExpanded && renderEntries(path, depth + 1)}
              </div>
            );
          }
          return (
            <div
              key={`file:${path}`}
              role="button"
              tabIndex={0}
              className={cn(
                "group flex w-full cursor-pointer items-center gap-1.5 rounded-md py-1 pr-2 text-left transition-colors hover:bg-[var(--color-hover-fill)]",
                selectedPath === path && "bg-[var(--color-selection-fill)]",
              )}
              // Align file rows with directory NAMES (past the chevron column).
              style={{ paddingLeft: `${leftPadding + 20}px` }}
              data-testid="file-tree-file"
              data-path={path}
              title={path}
              onClick={() => onOpenFile(path)}
              onKeyDown={(event) => {
                // Only when the ROW itself is focused: Enter/Space on the nested
                // open-in-editor button bubbles here, and preventDefault would
                // cancel the button's own activation.
                if (event.target !== event.currentTarget) return;
                if (event.key === "Enter" || event.key === " ") {
                  event.preventDefault();
                  onOpenFile(path);
                }
              }}
            >
              <FileText className="h-3.5 w-3.5 shrink-0 text-text-muted" />
              <span className="min-w-0 flex-1 truncate font-mono text-[11px] text-text-secondary group-hover:text-text-primary">
                {entry.name}
              </span>
              <span className="ml-auto flex shrink-0 items-center gap-1.5">
                {onOpenInEditor && (
                  <button
                    type="button"
                    className="hidden shrink-0 rounded p-0.5 text-text-muted hover:text-text-primary group-focus-within:flex group-hover:flex"
                    title={openInEditorLabel}
                    aria-label={openInEditorLabel}
                    data-testid="file-tree-open"
                    onClick={(event) => {
                      event.stopPropagation();
                      onOpenInEditor(path);
                    }}
                  >
                    <SquareArrowOutUpRight aria-hidden="true" className="h-3 w-3" />
                  </button>
                )}
                {entry.size !== null && (
                  <span className="shrink-0 font-mono text-[10px] tabular-nums text-text-muted">
                    {formatBytes(entry.size)}
                  </span>
                )}
              </span>
            </div>
          );
        })}
      </>
    );
  };

  return (
    <div className="space-y-0.5" data-testid="file-tree">
      {renderEntries("", 0)}
    </div>
  );
}
