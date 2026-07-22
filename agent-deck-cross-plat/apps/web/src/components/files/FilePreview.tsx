import { Suspense, lazy, useCallback, useEffect, useRef, useState } from "react";
import { AlertTriangle, Check, Code2, Eye, Loader2 } from "lucide-react";
import type { EditorId } from "@agent-deck/contracts";
import type { FileContentKind } from "@agent-deck/contracts";
import { cn } from "@/lib/cn";
import { FileSaveCoordinator } from "../../lib/fileSaveCoordinator.ts";
import { MarkdownDocument } from "../../design-system/markdown/MarkdownDocument.tsx";
import { fetchFileRead, fetchFileWrite } from "../../state/wsBridge.ts";
import { OpenInPicker } from "../diff/OpenInPicker.tsx";
import { isMarkdownPreviewFile } from "./filePreviewMode.ts";

/**
 * The read-only file preview (Slice 13b → upgraded L4a) — one open file's body
 * in the Files panel. Delivery kinds come straight from the server's bounded
 * read; L4a swaps the TEXT branch's plain virtualized lines for a lazy-loaded,
 * syntax-highlighted CodeMirror 6 view (read-only), and adds a raw/preview
 * toggle for markdown. The image / binary / truncated / empty branches are
 * UNCHANGED.
 *
 *   - text   → CodeMirror 6 (highlighted, read-only, line-numbered). For .md/.mdx
 *              a Code2/Eye toggle switches between this raw view and a rendered
 *              MarkdownDocument preview (default: preview).
 *   - image  → the whole-file `data:` URI in an <img>.
 *   - binary → a placeholder (a non-text file, or an over-cap image).
 *
 * The header (path + open-in-editor + md toggle) lives HERE (not the panel) so
 * each keep-alive file body owns its own path label and raw/preview mode — both
 * survive tab switches (the panel renders one FilePreview per open file, hiding
 * the inactive ones with display:none).
 *
 * CodeMirror is `React.lazy`-imported so its chunk (editor + grammar registry)
 * only loads when a text file is first opened; a plain <pre> shows meanwhile.
 */

const CodeMirrorView = lazy(() => import("./CodeMirrorView.tsx"));

/** Debounce (ms) after the last keystroke before an edit autosaves (Slice L4b). */
const AUTOSAVE_DEBOUNCE_MS = 700;

interface PreviewState {
  path: string;
  sessionId: string;
  status: "loading" | "loaded" | "error";
  contentKind: FileContentKind;
  content: string;
  byteLength: number;
  truncated: boolean;
  /** The version token from the read — the autosave conflict guard's base. */
  version: string;
  error?: string;
}

/** The autosave status surfaced in the file header chip (Slice L4b). `idle`
 * hides the chip; `conflict` also offers a reload affordance. */
type SaveStatus = "idle" | "saving" | "saved" | "failed" | "conflict";

/** Human-readable file size (kB/MB with one decimal past 1 kB). */
function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} kB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function NoticeBar({ children }: { children: string }) {
  return (
    <p
      className="shrink-0 border-b border-border-subtle bg-[var(--color-hover-fill)] px-3 py-1.5 text-[11px] text-text-muted"
      data-testid="file-preview-notice"
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

export interface FilePreviewEditorProps {
  /** Server-detected editors (for the header's open-in-editor picker). */
  available: readonly EditorId[];
  preferred: EditorId | null;
  /** Open this file in `editor` (or the preferred one when undefined). */
  onOpenInEditor: (editor?: EditorId) => void;
}

export function FilePreview(props: {
  path: string;
  sessionId: string;
  /** Whether this file's tab is the active (visible) one — inactive bodies are
   * display:none (keep-alive), which zero-sizes a CodeMirror view until shown. */
  isVisible: boolean;
  editors: FilePreviewEditorProps;
}) {
  const { path, sessionId, isVisible, editors } = props;
  const [state, setState] = useState<PreviewState | null>(null);
  // Markdown default: PREVIEW (matches t3code) — a rendered doc is the useful
  // default for a .md; the Code2/Eye toggle flips to the raw CodeMirror view.
  const [markdownMode, setMarkdownMode] = useState<"preview" | "raw">("preview");

  // Autosave (Slice L4b). versionRef is the conflict guard's base token: set on
  // each (re)load and advanced to the returned token after every successful
  // write. saveStatus drives the header chip. The coordinator debounces edits.
  const [saveStatus, setSaveStatus] = useState<SaveStatus>("idle");
  const versionRef = useRef<string>("");
  const coordinatorRef = useRef<FileSaveCoordinator | null>(null);

  // (Re)load the file's bounded content + version token. Shared by the mount
  // fetch and the conflict "reload" affordance. A stale guard drops a response
  // that resolves after the file/session changed underneath it.
  const load = useCallback(() => {
    let stale = false;
    setState({
      path,
      sessionId,
      status: "loading",
      contentKind: "text",
      content: "",
      byteLength: 0,
      truncated: false,
      version: "",
    });
    void fetchFileRead(path)
      .then((result) => {
        if (stale || result === null) return;
        versionRef.current = result.version;
        setState({
          path,
          sessionId,
          status: "loaded",
          contentKind: result.contentKind,
          content: result.content,
          byteLength: result.byteLength,
          truncated: result.truncated,
          version: result.version,
        });
      })
      .catch((error: unknown) => {
        if (stale) return;
        setState({
          path,
          sessionId,
          status: "error",
          contentKind: "text",
          content: "",
          byteLength: 0,
          truncated: false,
          version: "",
          error: error instanceof Error ? error.message : String(error),
        });
      });
    return () => {
      stale = true;
    };
  }, [path, sessionId]);

  useEffect(() => load(), [load]);

  // Persist the latest buffer through the conflict-guarded file_write. Returns
  // true on a landed write (advancing the base token); false on failure or an
  // on-disk conflict (the buffer is KEPT and the chip surfaces the reason).
  const persist = useCallback(
    async (contents: string): Promise<boolean> => {
      setSaveStatus("saving");
      try {
        const result = await fetchFileWrite(path, contents, versionRef.current);
        if (result === null) {
          setSaveStatus("failed");
          return false;
        }
        if (result.outcome === "conflict") {
          // Do NOT adopt the on-disk token — keep the user's buffer and let them
          // reload; a subsequent write would keep conflicting until they do.
          setSaveStatus("conflict");
          return false;
        }
        versionRef.current = result.version;
        setSaveStatus("saved");
        return true;
      } catch {
        setSaveStatus("failed");
        return false;
      }
    },
    [path],
  );

  // One coordinator per open file (recreated only if `persist` changes, i.e. the
  // path changes). Dispose on unmount / file-switch FLUSHES any pending edit so
  // a close never drops the last keystrokes.
  useEffect(() => {
    const coordinator = new FileSaveCoordinator({
      debounceMs: AUTOSAVE_DEBOUNCE_MS,
      persist,
      // As soon as an edit is queued (before the debounce fires) reflect it in
      // the chip, so it never shows a stale "Saved" while the buffer is dirty.
      // The `false` (confirmed) transition is owned by `persist` → "saved".
      onPendingChange: (pending) => {
        if (pending) setSaveStatus("saving");
      },
      onConfirmed: () => {},
    });
    coordinatorRef.current = coordinator;
    return () => {
      coordinator.dispose();
      coordinatorRef.current = null;
    };
  }, [persist]);

  const handleEditorChange = useCallback((value: string) => {
    coordinatorRef.current?.change(value);
  }, []);

  const reload = useCallback(() => {
    // Discard the losing buffer's pending write (never flush it) and refetch.
    coordinatorRef.current?.cancel();
    setSaveStatus("idle");
    load();
  }, [load]);

  // Only render content whose tag matches the currently-requested file (guards
  // the frame between selecting a new file and the fetch effect replacing state).
  const active =
    state !== null && state.path === path && state.sessionId === sessionId ? state : null;

  const isMarkdown = isMarkdownPreviewFile(path);
  const isTextLoaded = active?.status === "loaded" && active.contentKind === "text";
  const showMarkdownToggle = isMarkdown && isTextLoaded;
  // Editable = a loaded, non-truncated text file. Binary/image never reach the
  // editor; a TRUNCATED read stays read-only (saving it would drop the tail).
  const editable = isTextLoaded && active !== null && !active.truncated;

  return (
    <div className="flex min-h-0 flex-1 flex-col" data-testid="file-preview">
      {/* File header: path + save-status chip + open-in-editor + (.md) toggle.
          The picker reveals on header hover/focus so the resting layout is
          unchanged; the md toggle is always visible when applicable. */}
      <div className="group/fileheader flex items-center gap-2 border-b border-border-subtle bg-surface px-3 py-1.5">
        <span
          className="min-w-0 flex-1 truncate font-mono text-[11px] text-text-primary"
          data-testid="file-preview-path"
          title={path}
        >
          {path}
        </span>
        {editable && <SaveStatusChip status={saveStatus} onReload={reload} />}
        {showMarkdownToggle && (
          <div
            className="flex shrink-0 items-center rounded-md border border-border-subtle"
            data-testid="file-preview-mode-toggle"
            role="group"
            aria-label="Markdown view mode"
          >
            <button
              type="button"
              className={cn(
                "flex items-center rounded-l-md p-1 transition-colors",
                markdownMode === "preview"
                  ? "bg-[var(--color-selection-fill)] text-text-primary"
                  : "text-text-muted hover:bg-[var(--color-hover-fill)] hover:text-text-primary",
              )}
              title="Preview"
              aria-label="Preview markdown"
              aria-pressed={markdownMode === "preview"}
              data-testid="file-preview-mode-preview"
              onClick={() => setMarkdownMode("preview")}
            >
              <Eye className="h-3.5 w-3.5" />
            </button>
            <button
              type="button"
              className={cn(
                "flex items-center rounded-r-md p-1 transition-colors",
                markdownMode === "raw"
                  ? "bg-[var(--color-selection-fill)] text-text-primary"
                  : "text-text-muted hover:bg-[var(--color-hover-fill)] hover:text-text-primary",
              )}
              title="Raw"
              aria-label="Raw markdown"
              aria-pressed={markdownMode === "raw"}
              data-testid="file-preview-mode-raw"
              onClick={() => setMarkdownMode("raw")}
            >
              <Code2 className="h-3.5 w-3.5" />
            </button>
          </div>
        )}
        <OpenInPicker
          available={editors.available}
          preferred={editors.preferred}
          className="hidden group-focus-within/fileheader:flex group-hover/fileheader:flex"
          onOpen={editors.onOpenInEditor}
        />
      </div>

      <FilePreviewBody
        active={active}
        path={path}
        isVisible={isVisible}
        isMarkdown={isMarkdown}
        markdownMode={markdownMode}
        editable={editable}
        onEditorChange={handleEditorChange}
      />
    </div>
  );
}

/** The header save-status chip (Slice L4b). Hidden at idle; on a conflict it
 * offers a reload button that refetches the on-disk version + content. */
function SaveStatusChip({ status, onReload }: { status: SaveStatus; onReload: () => void }) {
  if (status === "idle") return null;
  const label =
    status === "saving"
      ? "Saving…"
      : status === "saved"
        ? "Saved"
        : status === "failed"
          ? "Save failed"
          : "Changed on disk";
  return (
    <span
      className={cn(
        "flex shrink-0 items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-medium",
        status === "saved" && "text-text-muted",
        status === "saving" && "text-text-muted",
        (status === "failed" || status === "conflict") && "text-[var(--color-role-error)]",
      )}
      data-testid="file-save-status"
      data-status={status}
    >
      {status === "saving" && <Loader2 className="h-3 w-3 animate-spin" aria-hidden />}
      {status === "saved" && <Check className="h-3 w-3" aria-hidden />}
      {(status === "failed" || status === "conflict") && (
        <AlertTriangle className="h-3 w-3" aria-hidden />
      )}
      <span>{label}</span>
      {status === "conflict" && (
        <button
          type="button"
          className="ml-0.5 rounded px-1 underline underline-offset-2 hover:text-text-primary"
          data-testid="file-save-reload"
          onClick={onReload}
        >
          reload
        </button>
      )}
    </span>
  );
}

function FilePreviewBody(props: {
  active: PreviewState | null;
  path: string;
  isVisible: boolean;
  isMarkdown: boolean;
  markdownMode: "preview" | "raw";
  editable: boolean;
  onEditorChange: (value: string) => void;
}) {
  const { active, path, isVisible, isMarkdown, markdownMode, editable, onEditorChange } = props;

  if (active === null || active.status === "loading") {
    return <CenteredState testId="file-preview-loading">Loading file…</CenteredState>;
  }
  if (active.status === "error") {
    return (
      <CenteredState testId="file-preview-error">
        {`Couldn't open this file: ${active.error ?? "unknown error"}`}
      </CenteredState>
    );
  }
  if (active.contentKind === "image") {
    return (
      <div
        className="flex min-h-0 flex-1 items-center justify-center overflow-auto p-4"
        data-testid="file-preview-image"
      >
        <img
          src={active.content}
          alt={path}
          className="max-h-full max-w-full object-contain"
          style={{ imageRendering: "auto" }}
        />
      </div>
    );
  }
  if (active.contentKind === "binary") {
    return (
      <CenteredState testId="file-preview-binary">
        {`Binary file (${formatBytes(active.byteLength)}) — no preview available.`}
      </CenteredState>
    );
  }

  // Text.
  return (
    <div className="flex min-h-0 flex-1 flex-col">
      {active.truncated && (
        <NoticeBar>This file exceeded the preview limit — showing the first part only.</NoticeBar>
      )}
      {active.content.length === 0 ? (
        <CenteredState testId="file-preview-empty">This file is empty.</CenteredState>
      ) : isMarkdown && markdownMode === "preview" ? (
        <div className="min-h-0 flex-1 overflow-auto px-4 py-3" data-testid="file-preview-markdown">
          <MarkdownDocument source={active.content} />
        </div>
      ) : (
        <div className="relative min-h-0 flex-1 overflow-hidden" data-testid="file-preview-text">
          <Suspense
            fallback={
              <pre
                className="h-full overflow-auto whitespace-pre px-3 py-1 font-mono text-[11px] leading-[1.5] text-text-secondary"
                data-testid="file-preview-fallback"
              >
                {active.content}
              </pre>
            }
          >
            <CodeMirrorView
              value={active.content}
              filename={path}
              visible={isVisible}
              readOnly={!editable}
              onChange={onEditorChange}
            />
          </Suspense>
        </div>
      )}
    </div>
  );
}
