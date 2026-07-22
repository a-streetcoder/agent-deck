import { useEffect, useMemo, useRef, useState } from "react";
import CodeMirror, { EditorState, EditorView, type Extension } from "@uiw/react-codemirror";
import { LanguageDescription, syntaxHighlighting } from "@codemirror/language";
import { languages } from "@codemirror/language-data";
import { oneDarkHighlightStyle } from "@codemirror/theme-one-dark";

/**
 * The read-only CodeMirror 6 view (Slice L4a) — the TEXT branch of the file
 * preview. Lives in its OWN module so React.lazy splits the whole editor (and
 * its @codemirror/* + language-data grammar registry) into a SEPARATE chunk: a
 * session that never opens a code file pays zero CodeMirror bytes.
 *
 * The language grammar is lazy-loaded by FILENAME via
 * `LanguageDescription.matchFilename(languages, filename)?.load()` — only the one
 * grammar the open file needs is fetched, on demand. Until it resolves the view
 * renders WITHOUT a language (plain text, still line-numbered); it re-renders
 * with highlighting once the grammar loads.
 *
 * READ-ONLY for L4a via BOTH `EditorState.readOnly.of(true)` (blocks edits at the
 * state level) and `EditorView.editable.of(false)` (drops the contentEditable +
 * cursor). L4b flips this: pass `readOnly={false}` and wire the `onChange` /
 * save extension point (see the props) — the view is already structured for it.
 */

/** Chrome theme mapped to our design tokens (adapts to light/dark via CSS vars).
 * Token COLORS come from oneDarkHighlightStyle (added below); this only styles
 * the editor frame, gutter, and selection so the editor blends into our surface. */
const tokenTheme = EditorView.theme({
  "&": {
    backgroundColor: "transparent",
    color: "var(--color-text-secondary)",
    height: "100%",
    fontSize: "11px",
  },
  ".cm-content": {
    fontFamily:
      '"JetBrains Mono Variable", ui-monospace, SFMono-Regular, "Cascadia Mono", Consolas, monospace',
    padding: "4px 0",
  },
  ".cm-gutters": {
    backgroundColor: "transparent",
    color: "var(--color-text-muted)",
    border: "none",
    fontSize: "10px",
  },
  ".cm-lineNumbers .cm-gutterElement": {
    padding: "0 6px 0 8px",
    minWidth: "2.5rem",
  },
  ".cm-activeLine": { backgroundColor: "transparent" },
  ".cm-activeLineGutter": { backgroundColor: "transparent" },
  ".cm-cursor": { display: "none" },
  ".cm-selectionBackground, ::selection": {
    backgroundColor: "var(--color-selection-fill)",
  },
  "&.cm-focused .cm-selectionBackground": {
    backgroundColor: "var(--color-selection-fill)",
  },
  ".cm-scroller": { overflow: "auto" },
});

export interface CodeMirrorViewProps {
  /** File text. */
  value: string;
  /** Repo-relative path — used only to pick the language grammar by extension. */
  filename: string;
  /**
   * L4b extension point. Defaults to true (read-only) for L4a. When L4b flips
   * this to false it should also pass `onChange` to capture edits for save.
   */
  readOnly?: boolean;
  /** L4b extension point: fired on edits once `readOnly` is false. */
  onChange?: (value: string) => void;
  /**
   * Whether this editor's tab is currently visible. A CodeMirror hidden via
   * `display:none` (keep-alive) measures a 0×0 viewport; on becoming visible
   * again it renders blank until told to re-measure. We `requestMeasure()` when
   * `visible` flips true so a background file tab paints correctly on return.
   */
  visible?: boolean;
}

export default function CodeMirrorView(props: CodeMirrorViewProps) {
  const { value, filename, readOnly = true, onChange, visible = true } = props;
  const [languageExtension, setLanguageExtension] = useState<Extension | null>(null);
  const viewRef = useRef<EditorView | null>(null);

  // Re-measure when the tab becomes visible again (a display:none CodeMirror
  // measures 0 height and paints blank until it re-measures).
  useEffect(() => {
    if (!visible) return;
    const raf = requestAnimationFrame(() => viewRef.current?.requestMeasure());
    return () => cancelAnimationFrame(raf);
  }, [visible]);

  // Lazy-load ONLY the grammar this filename needs (its dynamic import chunk).
  useEffect(() => {
    let stale = false;
    setLanguageExtension(null);
    const description = LanguageDescription.matchFilename(languages, filename);
    if (!description) return;
    void description
      .load()
      .then((support) => {
        if (!stale) setLanguageExtension(support);
      })
      .catch(() => {
        // Grammar failed to load — the view stays plain text (no highlighting).
      });
    return () => {
      stale = true;
    };
  }, [filename]);

  const extensions = useMemo<Extension[]>(() => {
    const list: Extension[] = [
      tokenTheme,
      syntaxHighlighting(oneDarkHighlightStyle),
      EditorState.readOnly.of(readOnly),
      EditorView.editable.of(!readOnly),
      EditorView.contentAttributes.of({ tabindex: "0" }),
    ];
    if (languageExtension) list.push(languageExtension);
    return list;
  }, [languageExtension, readOnly]);

  return (
    <CodeMirror
      value={value}
      extensions={extensions}
      onChange={readOnly ? undefined : onChange}
      onCreateEditor={(view) => {
        viewRef.current = view;
      }}
      editable={!readOnly}
      readOnly={readOnly}
      height="100%"
      style={{ height: "100%" }}
      // No line wrapping (decision: horizontal scroll preserves code layout; a
      // soft-wrap toggle is deferred to L4b). Line numbers + fold gutter come
      // from basicSetup; drop the noisy read-only extras.
      basicSetup={{
        lineNumbers: true,
        highlightActiveLine: false,
        highlightActiveLineGutter: false,
        foldGutter: false,
        autocompletion: false,
        highlightSelectionMatches: false,
      }}
    />
  );
}
