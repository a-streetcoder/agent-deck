import { useCallback, useEffect, useRef, useState } from "react";
import { FileText } from "lucide-react";
import { cn } from "@/lib/cn";
import { useAppStore } from "../state/store.ts";

/**
 * Instructions editor — pi's AGENTS.md context files, which pi auto-loads every
 * turn (agent-deck-system-prompt-logic §context files). Two scopes: the current
 * project's AGENTS.md at its root, and the GLOBAL ~/.pi/agent/AGENTS.md that
 * applies to every session. Global is editable with no project selected.
 */
type Scope = "project" | "global";

export function InstructionsScreen() {
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const projects = useAppStore((state) => state.projects);
  const setError = useAppStore((state) => state.setError);
  const project = projects.find((p) => p.id === currentProjectId) ?? null;

  const [scope, setScope] = useState<Scope>(currentProjectId ? "project" : "global");
  const [content, setContent] = useState("");
  const [savedContent, setSavedContent] = useState("");
  const [filePath, setFilePath] = useState("");
  const [loaded, setLoaded] = useState(false);
  const [saving, setSaving] = useState(false);
  const activeKey = useRef<string | null>(null);
  const loadedKey = useRef<string | null>(null);

  // The current edit target. `key` identifies it (for stale-load guarding);
  // `url` is null only for project scope with no project selected.
  const key = scope === "global" ? "global" : (currentProjectId ?? null);
  const url =
    scope === "global"
      ? "/runtime/instructions"
      : currentProjectId
        ? `/projects/${encodeURIComponent(currentProjectId)}/instructions`
        : null;

  const load = useCallback(
    async (loadKey: string, loadUrl: string): Promise<void> => {
      activeKey.current = loadKey;
      try {
        const response = await fetch(loadUrl);
        if (!response.ok) throw new Error(await response.text());
        const data = (await response.json()) as { content: string; path: string };
        if (activeKey.current !== loadKey) return;
        setContent(data.content);
        setSavedContent(data.content);
        setFilePath(data.path);
      } catch (err) {
        setError(String(err));
      } finally {
        // Reveal the editor only after the first load, so a fill/keystroke can't
        // race the load resetting the controlled value.
        if (activeKey.current === loadKey) setLoaded(true);
      }
    },
    [setError],
  );

  useEffect(() => {
    // (Re)load when the target changes — scope toggle or project switch. Loading
    // once per key avoids a re-fire clobbering unsaved edits.
    if (key && url && loadedKey.current !== key) {
      loadedKey.current = key;
      setLoaded(false);
      setContent("");
      setSavedContent("");
      void load(key, url);
    }
  }, [key, url, load]);

  const save = async (): Promise<void> => {
    if (!url) return;
    setSaving(true);
    try {
      const response = await fetch(url, {
        method: "PUT",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ content }),
      });
      if (!response.ok) throw new Error(await response.text());
      setSavedContent(content);
    } catch (err) {
      setError(String(err));
    } finally {
      setSaving(false);
    }
  };

  const dirty = content !== savedContent;
  const needsProject = scope === "project" && !project;

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
              {scope === "global" ? "Global" : (project?.name ?? "Project")} · AGENTS.md
            </h2>
          </div>
          <div className="flex items-center gap-2">
            <div
              className="flex items-center gap-0.5 rounded-capsule border border-border-subtle p-0.5"
              role="group"
              aria-label="Instructions scope"
            >
              {(["project", "global"] as const).map((s) => (
                <button
                  key={s}
                  data-testid={`instructions-scope-${s}`}
                  aria-pressed={scope === s}
                  className={cn(
                    "rounded-capsule px-2.5 py-0.5 text-xs capitalize transition-colors",
                    scope === s
                      ? "bg-[var(--color-selection-fill)] text-text-primary"
                      : "text-text-muted hover:text-text-primary",
                  )}
                  onClick={() => setScope(s)}
                >
                  {s}
                </button>
              ))}
            </div>
            <button
              data-testid="instructions-save"
              className="rounded-capsule px-3 py-1 text-xs font-medium shadow-capsule disabled:opacity-40"
              style={{
                background:
                  "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
                color: "var(--color-accent-foreground)",
              }}
              disabled={!dirty || saving || !loaded || needsProject}
              onClick={() => void save()}
            >
              {saving ? "Saving…" : dirty ? "Save" : "Saved"}
            </button>
          </div>
        </div>

        {needsProject ? (
          <div
            className="flex min-h-0 flex-1 items-center justify-center px-6 text-center"
            data-testid="instructions-no-project"
          >
            <div className="max-w-sm text-sm text-text-muted">
              Select a project in the sidebar to edit its{" "}
              <code className="rounded bg-surface px-1 font-mono text-xs">AGENTS.md</code>, or
              switch to <b>Global</b> to edit the instructions that apply to every session.
            </div>
          </div>
        ) : (
          <>
            <p className="truncate pb-3 font-mono text-[11px] text-text-muted" title={filePath}>
              {filePath}
            </p>
            {loaded ? (
              <textarea
                data-testid="instructions-editor"
                className="min-h-0 flex-1 resize-none rounded-2xl border border-border-subtle bg-surface p-4 font-mono text-sm text-text-primary outline-none focus:border-accent"
                placeholder={
                  scope === "global"
                    ? "Global context pi reads for every session. Markdown."
                    : "Project context pi reads on every turn. Markdown."
                }
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
          </>
        )}
      </div>
    </div>
  );
}
