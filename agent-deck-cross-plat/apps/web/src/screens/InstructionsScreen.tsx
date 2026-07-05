import { useCallback, useEffect, useRef, useState } from "react";
import { FileText } from "lucide-react";
import { useAppStore } from "../state/store.ts";

/**
 * Project instructions editor — pi's canonical AGENTS.md at the project root,
 * which pi auto-loads as context every turn (SystemInstructionsViews). Scoped
 * to the current project; the Default workspace prompts you to pick one.
 */
export function InstructionsScreen() {
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const projects = useAppStore((state) => state.projects);
  const setError = useAppStore((state) => state.setError);
  const project = projects.find((p) => p.id === currentProjectId) ?? null;

  const [content, setContent] = useState("");
  const [savedContent, setSavedContent] = useState("");
  const [filePath, setFilePath] = useState("");
  const [loaded, setLoaded] = useState(false);
  const [saving, setSaving] = useState(false);
  const activeProject = useRef<string | null>(null);
  const loadedProject = useRef<string | null>(null);

  const load = useCallback(
    async (projectId: string): Promise<void> => {
      activeProject.current = projectId;
      try {
        const response = await fetch(`/projects/${encodeURIComponent(projectId)}/instructions`);
        if (!response.ok) throw new Error(await response.text());
        const data = (await response.json()) as { content: string; path: string };
        if (activeProject.current !== projectId) return;
        setContent(data.content);
        setSavedContent(data.content);
        setFilePath(data.path);
      } catch (err) {
        setError(String(err));
      } finally {
        // Reveal the editor only after the first load, so a fill/keystroke can't
        // race the load resetting the controlled value.
        if (activeProject.current === projectId) setLoaded(true);
      }
    },
    [setError],
  );

  useEffect(() => {
    // Load once per project — the project-activation flow can re-fire this
    // effect, and a second load would clobber unsaved edits.
    if (currentProjectId && loadedProject.current !== currentProjectId) {
      loadedProject.current = currentProjectId;
      // Switching projects: hide the editor and clear the previous project's
      // content until the new one loads, so Save can't PUT stale content to it.
      setLoaded(false);
      setContent("");
      setSavedContent("");
      void load(currentProjectId);
    }
  }, [currentProjectId, load]);

  const save = async (): Promise<void> => {
    if (!currentProjectId) return;
    setSaving(true);
    try {
      const response = await fetch(
        `/projects/${encodeURIComponent(currentProjectId)}/instructions`,
        {
          method: "PUT",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ content }),
        },
      );
      if (!response.ok) throw new Error(await response.text());
      setSavedContent(content);
    } catch (err) {
      setError(String(err));
    } finally {
      setSaving(false);
    }
  };

  if (!project) {
    return (
      <div
        className="flex min-h-0 flex-1 items-center justify-center px-6 py-5 text-center"
        data-testid="instructions-screen"
      >
        <div className="max-w-sm text-sm text-text-muted" data-testid="instructions-no-project">
          Instructions are project-scoped. Select a project in the sidebar to edit its{" "}
          <code className="rounded bg-surface px-1 font-mono text-xs">AGENTS.md</code>.
        </div>
      </div>
    );
  }

  const dirty = content !== savedContent;

  return (
    <div className="min-h-0 flex-1 overflow-y-auto px-6 py-5" data-testid="instructions-screen">
      <div className="mx-auto flex h-full max-w-3xl flex-col">
        <div className="flex items-center justify-between pb-1">
          <div className="flex items-center gap-2">
            <FileText size={16} className="text-text-secondary" aria-hidden />
            <h2
              className="text-base font-semibold text-text-primary"
              style={{ fontStretch: "expanded" }}
            >
              {project.name} · AGENTS.md
            </h2>
          </div>
          <button
            data-testid="instructions-save"
            className="rounded-capsule px-3 py-1 text-xs font-medium shadow-capsule disabled:opacity-40"
            style={{
              background:
                "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
              color: "var(--color-accent-foreground)",
            }}
            disabled={!dirty || saving || !loaded}
            onClick={() => void save()}
          >
            {saving ? "Saving…" : dirty ? "Save" : "Saved"}
          </button>
        </div>
        <p className="truncate pb-3 font-mono text-[11px] text-text-muted" title={filePath}>
          {filePath}
        </p>
        {loaded ? (
          <textarea
            data-testid="instructions-editor"
            className="min-h-0 flex-1 resize-none rounded-2xl border border-border-subtle bg-surface p-4 font-mono text-sm text-text-primary outline-none focus:border-accent"
            placeholder="Project context pi reads on every turn. Markdown."
            spellCheck={false}
            value={content}
            onChange={(event) => setContent(event.target.value)}
          />
        ) : (
          <div
            className="flex min-h-0 flex-1 items-center justify-center rounded-2xl border border-border-subtle text-sm text-text-muted"
            data-testid="instructions-loading"
          >
            Loading…
          </div>
        )}
      </div>
    </div>
  );
}
