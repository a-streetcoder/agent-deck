import { Suspense, lazy, useEffect, useState } from "react";
import { Code2, Eye } from "lucide-react";
import type { EditorId } from "@agent-deck/contracts";
import type { FileContentKind } from "@agent-deck/contracts";
import { cn } from "@/lib/cn";
import { MarkdownDocument } from "../../design-system/markdown/MarkdownDocument.tsx";
import { fetchFileRead } from "../../state/wsBridge.ts";
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

interface PreviewState {
  path: string;
  sessionId: string;
  status: "loading" | "loaded" | "error";
  contentKind: FileContentKind;
  content: string;
  byteLength: number;
  truncated: boolean;
  error?: string;
}

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

  useEffect(() => {
    let stale = false;
    setState({
      path,
      sessionId,
      status: "loading",
      contentKind: "text",
      content: "",
      byteLength: 0,
      truncated: false,
    });
    void fetchFileRead(path)
      .then((result) => {
        if (stale || result === null) return;
        setState({
          path,
          sessionId,
          status: "loaded",
          contentKind: result.contentKind,
          content: result.content,
          byteLength: result.byteLength,
          truncated: result.truncated,
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
          error: error instanceof Error ? error.message : String(error),
        });
      });
    return () => {
      stale = true;
    };
  }, [path, sessionId]);

  // Only render content whose tag matches the currently-requested file (guards
  // the frame between selecting a new file and the fetch effect replacing state).
  const active =
    state !== null && state.path === path && state.sessionId === sessionId ? state : null;

  const isMarkdown = isMarkdownPreviewFile(path);
  const isTextLoaded = active?.status === "loaded" && active.contentKind === "text";
  const showMarkdownToggle = isMarkdown && isTextLoaded;

  return (
    <div className="flex min-h-0 flex-1 flex-col" data-testid="file-preview">
      {/* File header: path + open-in-editor + (for .md) the raw/preview toggle.
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
      />
    </div>
  );
}

function FilePreviewBody(props: {
  active: PreviewState | null;
  path: string;
  isVisible: boolean;
  isMarkdown: boolean;
  markdownMode: "preview" | "raw";
}) {
  const { active, path, isVisible, isMarkdown, markdownMode } = props;

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
            <CodeMirrorView value={active.content} filename={path} visible={isVisible} />
          </Suspense>
        </div>
      )}
    </div>
  );
}
