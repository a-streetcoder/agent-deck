import { useEffect, useMemo, useState } from "react";
import { Virtuoso } from "react-virtuoso";
import type { FileContentKind } from "@agent-deck/contracts";
import { fetchFileRead } from "../../state/wsBridge.ts";

/**
 * The read-only file preview (Slice 13b) — the right half of the Files panel
 * once a file is selected. Pattern-ported from t3code's `FilePreviewPanel.tsx`
 * (MIT) but deliberately reduced: the donor embeds a full `@pierre/diffs`
 * editor (shiki-class highlighting, editing, a worker pool). We render bounded
 * read-only content, so — exactly like the diff slice's decision
 * (lib/unifiedDiff.ts) — there is NO syntax-highlight library and NO worker:
 * the server caps text at FILE_READ_MAX_BYTES, we split it into lines and
 * virtualize them with react-virtuoso (the diff panel's renderer), so even a
 * max-size file mounts in a few ms and scrolls at viewport-DOM cost. Adding
 * shiki later (with a worker, per the donor) is a self-contained follow-up.
 *
 * Delivery kinds come straight from the server's bounded read:
 *   - text   → line-numbered monospace, virtualized; a `truncated` notice when
 *              the file exceeded the read cap.
 *   - image  → the whole-file `data:` URI in an <img> (server caps the inline
 *              image size; over the cap it arrives as `binary`).
 *   - binary → a placeholder (a non-text file, or an over-cap image).
 */

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

export function FilePreview(props: { path: string; sessionId: string }) {
  const { path, sessionId } = props;
  const [state, setState] = useState<PreviewState | null>(null);

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

  // Split into lines only for a loaded text file (the virtualized render). A
  // trailing newline yields a final empty line, matching an editor's view.
  const lines = useMemo(
    () =>
      state?.status === "loaded" && state.contentKind === "text" ? state.content.split("\n") : [],
    [state],
  );

  // Only render content whose tag matches the currently-requested file (guards
  // the frame between selecting a new file and the fetch effect replacing state).
  const active =
    state !== null && state.path === path && state.sessionId === sessionId ? state : null;

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
      ) : (
        /* `relative` is load-bearing: Virtuoso positions its measurement div
           absolutely and needs a positioned ancestor (same as the diff panel). */
        <div className="relative min-h-0 flex-1" data-testid="file-preview-text">
          <Virtuoso
            style={{ height: "100%" }}
            totalCount={lines.length}
            itemContent={(index) => (
              <div className="flex items-start font-mono text-[11px] leading-[1.5]">
                <span className="w-10 shrink-0 select-none pr-2 text-right tabular-nums text-[10px] leading-[1.65] text-text-muted/70">
                  {index + 1}
                </span>
                <span className="min-w-0 flex-1 whitespace-pre-wrap break-all pr-2 text-text-secondary">
                  {lines[index]!.length > 0 ? lines[index] : " "}
                </span>
              </div>
            )}
          />
        </div>
      )}
    </div>
  );
}
