import { useEffect, useState } from "react";
import { ArrowLeft, RefreshCw, X } from "lucide-react";
import { cn } from "@/lib/cn";
import { useAppStore } from "../../state/store.ts";
import { OpenInPicker, editorLabel, useOpenInEditor } from "../diff/OpenInPicker.tsx";
import { FilePreview } from "./FilePreview.tsx";
import { FileTree } from "./FileTree.tsx";
import { useFileTree } from "./useFileTree.ts";

/**
 * The file-navigation panel (Slice 13b): a right-hand aside on the chat surface,
 * a sibling to the diff panel — same shell idiom (fixed-width, subheader row,
 * lazy tree that widens into a tree-strip-over-content split when an item is
 * open). Pattern-ported from t3code's FileBrowserPanel + FilePreviewPanel (MIT)
 * onto our transport (lazy per-directory `file_list`) and tokens.
 *
 * Unlike the diff panel it is UNGATED by git: any session has a cwd, so the
 * toggle shows for every chat session. Mounted permanently but renders null
 * while closed — a session that never opens it pays nothing (no fetch, no tree).
 *
 * Open-in-editor (Slice 11 reuse): the preview header and each tree row expose
 * the OpenInPicker over the SAME server-detected editors the diff panel uses —
 * this covers the S11-deferred "explicit file surface" open action (the file
 * path is repo-relative and resolved inside the session cwd by editorLauncher).
 */
export function FilesPanel() {
  const open = useAppStore((state) => state.filesPanelOpen);
  const setOpen = useAppStore((state) => state.setFilesPanelOpen);
  const sessionId = useAppStore((state) => state.session?.id ?? null);

  const controller = useFileTree(sessionId);
  const [selectedPath, setSelectedPath] = useState<string | null>(null);
  const editorPicker = useOpenInEditor();

  // A session switch drops the previous file's preview back to the tree.
  useEffect(() => {
    setSelectedPath(null);
  }, [sessionId]);

  if (!open || sessionId === null) return null;

  const inPreview = selectedPath !== null;
  const rootState = controller.dirs.get("");

  return (
    <aside
      className="flex shrink-0 flex-col overflow-hidden border-l border-border-subtle bg-surface-elevated"
      style={{ width: inPreview ? "min(42vw, 560px)" : "300px" }}
      data-testid="files-panel"
    >
      {/* Subheader row (matches the diff panel's surface-subheader). */}
      <div className="flex items-center justify-between gap-2 border-b border-border-subtle px-3 py-2">
        <span
          className="text-xs font-semibold uppercase tracking-wide text-text-muted"
          style={{ fontStretch: "expanded" }}
        >
          Files
        </span>
        <div className="flex shrink-0 items-center gap-1">
          <button
            type="button"
            className="rounded p-1 text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
            title="Refresh files"
            aria-label="Refresh files"
            data-testid="files-refresh"
            onClick={() => controller.reload()}
          >
            <RefreshCw
              className={cn("h-3.5 w-3.5", rootState?.status === "loading" && "animate-spin")}
            />
          </button>
          <button
            type="button"
            className="rounded p-1 text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
            title="Close files panel"
            aria-label="Close files panel"
            data-testid="files-close"
            onClick={() => setOpen(false)}
          >
            <X className="h-3.5 w-3.5" />
          </button>
        </div>
      </div>

      {/* The tree. Fills the panel when nothing is open; keeps a capped strip on
          top (the donor's browser-over-preview stack) once a file is selected. */}
      <div
        className={cn(
          "overflow-y-auto px-1.5 py-1.5",
          inPreview ? "max-h-[38%] shrink-0 border-b border-border-subtle" : "min-h-0 flex-1",
        )}
      >
        <FileTree
          controller={controller}
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

      {inPreview && selectedPath !== null && (
        <div className="flex min-h-0 flex-1 flex-col" data-testid="file-preview">
          {/* File header: path + open-in-editor + back to the tree. The picker
              reveals on header hover/focus so the resting layout is unchanged. */}
          <div className="group/fileheader flex items-center gap-2 border-b border-border-subtle bg-surface px-3 py-1.5">
            <span
              className="min-w-0 flex-1 truncate font-mono text-[11px] text-text-primary"
              data-testid="file-preview-path"
              title={selectedPath}
            >
              {selectedPath}
            </span>
            <OpenInPicker
              available={editorPicker.available}
              preferred={editorPicker.preferred}
              className="hidden group-focus-within/fileheader:flex group-hover/fileheader:flex"
              onOpen={(editor) => {
                if (selectedPath !== null) editorPicker.open(selectedPath, undefined, editor);
              }}
            />
            <button
              type="button"
              className="shrink-0 rounded p-0.5 text-text-muted transition-colors hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
              title="Back to files"
              aria-label="Back to files"
              data-testid="file-back"
              onClick={() => setSelectedPath(null)}
            >
              <ArrowLeft className="h-3.5 w-3.5" />
            </button>
          </div>
          <FilePreview path={selectedPath} sessionId={sessionId} />
        </div>
      )}
    </aside>
  );
}
