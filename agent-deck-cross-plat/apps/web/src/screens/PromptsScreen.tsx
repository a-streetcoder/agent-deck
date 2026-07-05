import { useCallback, useEffect, useState } from "react";
import { MessageSquareText, Plus, Trash2 } from "lucide-react";
import type { PromptInfo } from "@agent-deck/domain";
import { cn } from "@/lib/cn";
import { useAppStore } from "../state/store.ts";

/**
 * Prompts screen (native piResources → Prompts): CRUD for prompt-template .md
 * files that pi exposes as `/prompt:<name>` commands. Single markdown files
 * with a name + description; project scope wins over global for the same name.
 */

interface Draft {
  name: string;
  description: string;
  body: string;
  scope: "global" | "project";
  /** The project this edit targets, captured when the editor opened. */
  projectId: string | null;
  original?: string; // set when editing an existing prompt (its name)
}

export function PromptsScreen() {
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const resourcesVersion = useAppStore((state) => state.resourcesVersion);
  const setError = useAppStore((state) => state.setError);
  const [prompts, setPrompts] = useState<PromptInfo[]>([]);
  const [draft, setDraft] = useState<Draft | null>(null);

  const load = useCallback(async (): Promise<void> => {
    const query = currentProjectId ? `?projectId=${encodeURIComponent(currentProjectId)}` : "";
    try {
      const response = await fetch(`/resources/prompts${query}`);
      if (!response.ok) throw new Error(await response.text());
      const data = (await response.json()) as { prompts: PromptInfo[] };
      setPrompts(data.prompts);
    } catch (err) {
      setError(String(err));
    }
  }, [currentProjectId, setError]);

  useEffect(() => {
    void load();
  }, [load, resourcesVersion]);

  // Close the editor when the project changes so an in-progress edit can't be
  // saved against a different project than it was opened in.
  useEffect(() => {
    setDraft(null);
  }, [currentProjectId]);

  const startNew = (): void =>
    setDraft({
      name: "",
      description: "",
      body: "",
      scope: currentProjectId ? "project" : "global",
      projectId: currentProjectId,
    });

  const startEdit = (prompt: PromptInfo): void =>
    setDraft({
      name: prompt.name,
      description: prompt.description ?? "",
      body: prompt.body,
      scope: prompt.scope === "project" ? "project" : "global",
      projectId: currentProjectId,
      original: prompt.name,
    });

  const save = async (): Promise<void> => {
    if (!draft || !draft.name.trim()) return;
    try {
      const response = await fetch("/resources/prompts", {
        method: "PUT",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          projectId: draft.projectId ?? undefined,
          scope: draft.scope,
          name: draft.name.trim(),
          edit: { description: draft.description, body: draft.body },
        }),
      });
      if (!response.ok) throw new Error(await response.text());
      setDraft(null);
      await load();
    } catch (err) {
      setError(String(err));
    }
  };

  const remove = async (prompt: PromptInfo): Promise<void> => {
    try {
      const response = await fetch("/resources/prompts", {
        method: "DELETE",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          projectId: currentProjectId ?? undefined,
          scope: prompt.scope === "project" ? "project" : "global",
          name: prompt.name,
        }),
      });
      if (!response.ok) throw new Error(await response.text());
      await load();
    } catch (err) {
      setError(String(err));
    }
  };

  return (
    <div className="min-h-0 flex-1 overflow-y-auto px-6 py-5" data-testid="prompts-screen">
      <div className="mx-auto max-w-3xl">
        <div className="flex items-center justify-between pb-1">
          <div className="flex items-center gap-2">
            <MessageSquareText size={16} className="text-text-secondary" aria-hidden />
            <h2
              className="text-base font-semibold text-text-primary"
              style={{ fontStretch: "expanded" }}
            >
              Prompt templates
            </h2>
          </div>
          <button
            data-testid="prompt-new"
            className="flex items-center gap-1.5 rounded-capsule px-3 py-1 text-xs font-medium shadow-capsule"
            style={{
              background:
                "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
              color: "var(--color-accent-foreground)",
            }}
            onClick={startNew}
          >
            <Plus size={13} /> New prompt
          </button>
        </div>
        <p className="pb-3 text-xs text-text-muted">
          Reusable prompts pi exposes as <code className="font-mono">/prompt:&lt;name&gt;</code>{" "}
          commands. Project prompts override global ones of the same name.
        </p>

        {draft ? (
          <div
            className="mb-4 space-y-2 rounded-2xl border border-border-strong bg-surface-elevated p-4"
            data-testid="prompt-editor"
          >
            <input
              data-testid="prompt-name"
              className="w-full rounded-lg border border-border-strong bg-surface px-2.5 py-1.5 font-mono text-sm text-text-primary outline-none focus:border-accent disabled:opacity-50"
              placeholder="name (e.g. review)"
              value={draft.name}
              disabled={draft.original !== undefined}
              onChange={(e) => setDraft({ ...draft, name: e.target.value })}
            />
            <input
              data-testid="prompt-description"
              className="w-full rounded-lg border border-border-strong bg-surface px-2.5 py-1.5 text-sm text-text-primary outline-none focus:border-accent"
              placeholder="description"
              value={draft.description}
              onChange={(e) => setDraft({ ...draft, description: e.target.value })}
            />
            <textarea
              data-testid="prompt-body"
              className="h-48 w-full resize-none rounded-lg border border-border-strong bg-surface p-3 font-mono text-sm text-text-primary outline-none focus:border-accent"
              placeholder="The prompt template. Markdown."
              spellCheck={false}
              value={draft.body}
              onChange={(e) => setDraft({ ...draft, body: e.target.value })}
            />
            <div className="flex items-center justify-end gap-2">
              <button
                className="rounded-capsule px-3 py-1 text-xs text-text-secondary hover:text-text-primary"
                onClick={() => setDraft(null)}
              >
                Cancel
              </button>
              <button
                data-testid="prompt-save"
                className="rounded-capsule px-3 py-1 text-xs font-medium shadow-capsule disabled:opacity-40"
                style={{
                  background:
                    "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
                  color: "var(--color-accent-foreground)",
                }}
                disabled={!draft.name.trim()}
                onClick={() => void save()}
              >
                Save
              </button>
            </div>
          </div>
        ) : null}

        <div className="space-y-1.5" data-testid="prompt-list">
          {prompts.map((prompt) => (
            <div
              key={`${prompt.scope}:${prompt.name}`}
              data-prompt-name={prompt.name}
              className="group flex items-center gap-3 rounded-[14px] border border-border-subtle bg-surface px-3.5 py-2.5"
            >
              <button
                className="flex min-w-0 flex-1 items-center gap-3 text-left"
                onClick={() => startEdit(prompt)}
              >
                <span
                  className="font-mono text-sm font-medium text-text-primary"
                  style={{ fontStretch: "expanded" }}
                >
                  /prompt:{prompt.name}
                </span>
                <span
                  data-testid="scope-chip"
                  data-scope={prompt.scope}
                  className={cn(
                    "rounded-capsule border px-1.5 text-[10px]",
                    prompt.scope === "project"
                      ? "border-border-strong text-text-secondary"
                      : "border-border-subtle text-text-muted",
                  )}
                >
                  {prompt.scope}
                </span>
                {prompt.description ? (
                  <span className="min-w-0 flex-1 truncate text-xs text-text-muted">
                    {prompt.description}
                  </span>
                ) : null}
              </button>
              <button
                data-testid={`prompt-delete-${prompt.name}`}
                className="rounded p-1 text-text-muted opacity-0 transition-opacity hover:text-[var(--color-role-error)] group-hover:opacity-100"
                title="Delete"
                onClick={() => void remove(prompt)}
              >
                <Trash2 size={13} />
              </button>
            </div>
          ))}
          {prompts.length === 0 && !draft ? (
            <div className="py-8 text-center text-sm text-text-muted">
              No prompt templates yet. Create one to use it as a slash command.
            </div>
          ) : null}
        </div>
      </div>
    </div>
  );
}
