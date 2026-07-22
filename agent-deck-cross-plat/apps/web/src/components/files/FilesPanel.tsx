import { useCallback, useEffect, useRef, useState } from "react";
import { RefreshCw, X } from "lucide-react";
import { cn } from "@/lib/cn";
import { useAppStore } from "../../state/store.ts";
import { ResizeHandle, useResizable } from "../common/Resizable.tsx";
import { editorLabel, useOpenInEditor } from "../diff/OpenInPicker.tsx";
import { FilePreview } from "./FilePreview.tsx";
import { FileTree } from "./FileTree.tsx";
import { useFileTree } from "./useFileTree.ts";

/**
 * The file-navigation panel (Slice 13b → upgraded L4a): a SIDE-BY-SIDE
 * [tree | content] workspace. The old REPLACE-nav (a tree strip that collapsed
 * over a single preview with a back button) is gone; instead the tree stays on
 * the left and MULTIPLE files open as Chrome-style page-tabs on the right,
 * mirroring the L2 BrowserPanel page-tabs model EXACTLY:
 *   - `openFiles[]` + `activeFileId` (component-local, like BrowserPanel pages);
 *   - a render-synced `openFilesRef` so open/close updaters stay PURE
 *     (StrictMode-safe — create the tab OUTSIDE the setState updater);
 *   - dedupe by path: re-opening an already-open file just focuses its tab;
 *   - KEEP-ALIVE — one FilePreview per open file, inactive ones hidden via
 *     display:none so each file keeps its scroll / CodeMirror / md-mode state.
 *
 * The tree|content split has a draggable divider (persisted width). The whole
 * panel is one workspace tab body; it unmounts (resetting open files) only when
 * the Files tab is closed.
 */

/** Cap on simultaneously-open file tabs (mirrors BrowserPanel's page cap). */
const MAX_FILES = 12;

const TREE_WIDTH_KEY = "agentdeck:files-tree-width";

interface OpenFile {
  readonly id: string;
  readonly path: string;
}

let fileSeq = 0;
function newOpenFile(path: string): OpenFile {
  fileSeq += 1;
  return { id: `files-tab-${fileSeq}`, path };
}

function basename(path: string): string {
  const parts = path.split("/");
  return parts[parts.length - 1] || path;
}

export function FilesPanel() {
  const sessionId = useAppStore((state) => state.session?.id ?? null);

  const controller = useFileTree(sessionId);
  const editorPicker = useOpenInEditor();

  const [openFiles, setOpenFiles] = useState<OpenFile[]>([]);
  const [activeFileId, setActiveFileId] = useState<string | null>(null);
  // Render-synced mirror so open/close read the live array (pure updaters).
  const openFilesRef = useRef<OpenFile[]>(openFiles);
  openFilesRef.current = openFiles;

  const tree = useResizable({
    storageKey: TREE_WIDTH_KEY,
    defaultWidth: 190,
    min: 140,
    max: 460,
    edge: "right",
  });

  // A session switch drops the previous project's open file tabs.
  useEffect(() => {
    setOpenFiles([]);
    setActiveFileId(null);
  }, [sessionId]);

  const openFile = useCallback((path: string) => {
    const existing = openFilesRef.current.find((file) => file.path === path);
    if (existing) {
      setActiveFileId(existing.id);
      return;
    }
    if (openFilesRef.current.length >= MAX_FILES) {
      console.warn(`[files] tab cap (${MAX_FILES}) reached — close a file to open another`);
      return;
    }
    const file = newOpenFile(path); // created ONCE, outside the updater
    setOpenFiles((prev) => [...prev, file]);
    setActiveFileId(file.id);
  }, []);

  const closeFile = useCallback((id: string) => {
    const prev = openFilesRef.current;
    const index = prev.findIndex((file) => file.id === id);
    const next = prev.filter((file) => file.id !== id);
    setOpenFiles(next);
    setActiveFileId((current) => {
      if (current !== id) return current;
      if (next.length === 0) return null;
      return next[Math.min(Math.max(index, 0), next.length - 1)]!.id;
    });
  }, []);

  if (sessionId === null) return null;

  const rootState = controller.dirs.get("");
  const activePath = openFiles.find((file) => file.id === activeFileId)?.path ?? null;
  const editorProps = {
    available: editorPicker.available,
    preferred: editorPicker.preferred,
  };

  return (
    <div className="flex min-h-0 flex-1 flex-col overflow-hidden" data-testid="files-panel">
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
        </div>
      </div>

      {/* Side-by-side [tree | content] with a draggable divider between them. */}
      <div className="flex min-h-0 flex-1">
        <div
          className="min-h-0 shrink-0 overflow-y-auto border-r border-border-subtle px-1.5 py-1.5"
          style={{ width: `${tree.width}px` }}
        >
          <FileTree
            controller={controller}
            onOpenFile={openFile}
            selectedPath={activePath}
            {...(editorPicker.available.length > 0 && editorPicker.preferred !== null
              ? {
                  openInEditorLabel: `Open in ${editorLabel(editorPicker.preferred)}`,
                  onOpenInEditor: (path: string) => editorPicker.open(path, undefined),
                }
              : {})}
          />
        </div>

        <ResizeHandle
          handleProps={tree.handleProps}
          isDragging={tree.isDragging}
          testId="files-tree-resize"
          ariaLabel="Resize file tree"
          width={tree.width}
          min={tree.min}
          max={tree.max}
        />

        <div className="flex min-h-0 min-w-0 flex-1 flex-col">
          {openFiles.length === 0 ? (
            <div
              className="flex flex-1 items-center justify-center px-5 text-center text-xs text-text-muted"
              data-testid="files-content-empty"
            >
              Select a file to preview.
            </div>
          ) : (
            <>
              {/* The open-file tab strip (mirrors BrowserPanel's page strip). */}
              <div
                className="flex items-center gap-1 border-b border-border-subtle px-1.5 py-1"
                data-testid="files-tab-strip"
              >
                <div
                  className="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto"
                  role="tablist"
                >
                  {openFiles.map((file, index) => {
                    const isActive = file.id === activeFileId;
                    const label = basename(file.path);
                    return (
                      <div
                        key={file.id}
                        className={cn(
                          "group flex h-7 min-w-0 max-w-40 shrink-0 items-center gap-1.5 rounded-md pl-2 pr-1 text-xs",
                          isActive
                            ? "bg-[var(--color-selection-fill)] text-text-primary"
                            : "text-text-muted hover:bg-[var(--color-hover-fill)] hover:text-text-primary",
                        )}
                      >
                        <button
                          type="button"
                          role="tab"
                          aria-selected={isActive}
                          className="flex min-w-0 flex-1 items-center gap-1.5"
                          data-testid={`files-tab-${index}`}
                          data-active={isActive}
                          data-path={file.path}
                          title={file.path}
                          onClick={() => setActiveFileId(file.id)}
                        >
                          <span className="truncate font-mono">{label}</span>
                        </button>
                        <button
                          type="button"
                          className={cn(
                            "flex size-4 shrink-0 items-center justify-center rounded hover:bg-[var(--color-hover-fill)] hover:text-text-primary",
                            isActive ? "opacity-100" : "opacity-0 group-hover:opacity-100",
                          )}
                          data-testid={`files-tab-close-${index}`}
                          aria-label={`Close ${label}`}
                          title={`Close ${label}`}
                          onClick={(event) => {
                            event.stopPropagation();
                            closeFile(file.id);
                          }}
                        >
                          <X className="h-3 w-3" aria-hidden />
                        </button>
                      </div>
                    );
                  })}
                </div>
              </div>

              {/* KEEP-ALIVE bodies: one FilePreview per open file, inactive ones
                  hidden with display:none so scroll / md-mode / CodeMirror state
                  survives tab switches (the BrowserPanel keep-alive idiom). */}
              <div className="relative min-h-0 flex-1">
                {openFiles.map((file) => (
                  <div
                    key={file.id}
                    className={cn(
                      "absolute inset-0 flex-col",
                      file.id === activeFileId ? "flex" : "hidden",
                    )}
                    data-testid={`files-body-${file.path}`}
                  >
                    <FilePreview
                      path={file.path}
                      sessionId={sessionId}
                      isVisible={file.id === activeFileId}
                      editors={{
                        ...editorProps,
                        onOpenInEditor: (editor) => editorPicker.open(file.path, undefined, editor),
                      }}
                    />
                  </div>
                ))}
              </div>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
