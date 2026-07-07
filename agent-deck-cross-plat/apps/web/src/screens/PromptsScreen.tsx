import { useCallback, useEffect, useRef, useState } from "react";
import { Check, Globe, MessageSquareText, Pencil, Plus, Trash2, X } from "lucide-react";
import type { PromptInfo } from "@agent-deck/domain";
import { cn } from "@/lib/cn";
import { useAppStore } from "../state/store.ts";

/**
 * Prompts screen (native piResources → Prompts): CRUD for prompt-template .md
 * files that pi exposes as `/<name>` slash commands (native prompt.invocation;
 * pi matches the file's basename). Single markdown files with a name +
 * description + optional argument-hint; project scope wins over global.
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
  // "All Projects" default prompt templates (native defaultPromptTemplateNames):
  // enabled ones are injected into every project's parent sessions as
  // --prompt-template flags. Tracked by name, read from app settings.
  const [defaultPrompts, setDefaultPrompts] = useState<string[]>([]);
  // Inline rename target (native RenameResourceSheet): the prompt being renamed.
  const [renaming, setRenaming] = useState<{
    name: string;
    scope: PromptInfo["scope"];
    value: string;
  } | null>(null);

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

  // Monotonic token: a slow /settings GET must not clobber a newer optimistic
  // flip or a newer refresh. Bumped on every refresh AND on every toggle.
  const defaultsSeq = useRef(0);
  const refreshDefaults = useCallback(async (): Promise<void> => {
    const seq = ++defaultsSeq.current;
    try {
      const response = await fetch("/settings");
      if (!response.ok) return;
      const { settings } = (await response.json()) as {
        settings: { defaultPromptTemplates?: string[] };
      };
      if (seq === defaultsSeq.current) setDefaultPrompts(settings.defaultPromptTemplates ?? []);
    } catch {
      // Non-fatal: the toggle just won't reflect state until the next refresh.
    }
  }, []);

  useEffect(() => {
    void load();
    void refreshDefaults();
  }, [load, refreshDefaults, resourcesVersion]);

  // Toggle a prompt's "All Projects" default (native defaultPromptTemplateNames).
  // The PATCH RESPONSE returns the authoritative updated settings, so we apply
  // that (not a separate GET) under a per-toggle token — the latest toggle wins
  // and no interleaved refresh can land stale state over a newer flip.
  const toggleDefault = async (name: string, enabled: boolean): Promise<void> => {
    const seq = ++defaultsSeq.current;
    // Optimistic — the toggle must flip immediately.
    setDefaultPrompts((prev) =>
      enabled ? [...new Set([...prev, name])] : prev.filter((n) => n !== name),
    );
    try {
      const response = await fetch("/settings", {
        method: "PATCH",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ setDefaultPromptTemplate: { name, enabled } }),
      });
      if (!response.ok) throw new Error(await response.text());
      const { settings } = (await response.json()) as {
        settings: { defaultPromptTemplates?: string[] };
      };
      // Reconcile to the server's authoritative list only if still the latest.
      if (seq === defaultsSeq.current) setDefaultPrompts(settings.defaultPromptTemplates ?? []);
    } catch (err) {
      // Revert the optimistic flip so the UI can't claim a change that failed.
      if (seq === defaultsSeq.current) {
        setDefaultPrompts((prev) =>
          enabled ? prev.filter((n) => n !== name) : [...new Set([...prev, name])],
        );
      }
      setError(String(err));
    }
  };

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

  const rename = async (): Promise<void> => {
    if (!renaming) return;
    const newName = renaming.value.trim();
    if (!newName || newName === renaming.name) {
      setRenaming(null);
      return;
    }
    try {
      const response = await fetch("/resources/prompts/rename", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          projectId: currentProjectId ?? undefined,
          scope: renaming.scope,
          name: renaming.name,
          newName,
        }),
      });
      if (!response.ok) {
        const { error } = (await response.json().catch(() => ({}))) as { error?: string };
        throw new Error(error ?? "Couldn't rename the prompt.");
      }
      setRenaming(null);
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
          Reusable prompts pi exposes as <code className="font-mono">/&lt;name&gt;</code> slash
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
              {renaming?.name === prompt.name && renaming.scope === prompt.scope ? (
                <>
                  <span className="font-mono text-sm text-text-muted">/</span>
                  <input
                    autoFocus
                    data-testid={`prompt-rename-input-${prompt.name}`}
                    className="min-w-0 flex-1 rounded-lg border border-border-strong bg-surface px-2 py-1 font-mono text-sm text-text-primary outline-none focus:border-accent"
                    value={renaming.value}
                    onChange={(e) => setRenaming({ ...renaming, value: e.target.value })}
                    onKeyDown={(e) => {
                      if (e.key === "Enter") void rename();
                      if (e.key === "Escape") setRenaming(null);
                    }}
                  />
                  <button
                    data-testid={`prompt-rename-confirm-${prompt.name}`}
                    className="rounded p-1 text-text-muted hover:text-[var(--color-brand-accent)]"
                    title="Rename"
                    onClick={() => void rename()}
                  >
                    <Check size={14} />
                  </button>
                  <button
                    data-testid={`prompt-rename-cancel-${prompt.name}`}
                    className="rounded p-1 text-text-muted hover:text-text-primary"
                    title="Cancel"
                    onClick={() => setRenaming(null)}
                  >
                    <X size={14} />
                  </button>
                </>
              ) : (
                <>
                  <button
                    className="flex min-w-0 flex-1 items-center gap-3 text-left"
                    onClick={() => startEdit(prompt)}
                  >
                    <span
                      data-testid="prompt-invocation"
                      className="font-mono text-sm font-medium text-text-primary"
                      style={{ fontStretch: "expanded" }}
                    >
                      {prompt.invocation}
                    </span>
                    {prompt.argumentHint ? (
                      <span
                        data-testid="prompt-argument-hint"
                        className="shrink-0 rounded-capsule border border-border-subtle px-1.5 font-mono text-[10px] text-text-muted"
                      >
                        {prompt.argumentHint}
                      </span>
                    ) : null}
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
                  {/* "All Projects" default is a GLOBAL concept — the backend
                      resolves a default name global-first, so the toggle is only
                      meaningful (and only shown) for global-scope prompts. */}
                  {prompt.scope === "global" &&
                    (() => {
                      const on = defaultPrompts.includes(prompt.name);
                      return (
                        <button
                          data-testid={`prompt-default-${prompt.name}`}
                          aria-pressed={on}
                          className={cn(
                            "flex shrink-0 items-center gap-1 rounded-capsule border px-1.5 py-0.5 text-[10px] transition-colors",
                            on
                              ? "border-border-strong bg-[var(--color-selection-fill)] text-text-primary"
                              : "border-border-subtle text-text-muted opacity-0 hover:text-text-primary group-hover:opacity-100",
                          )}
                          title={
                            on
                              ? "Enabled for All Projects — remove"
                              : "Enable this prompt for All Projects (injected as --prompt-template)"
                          }
                          onClick={() => void toggleDefault(prompt.name, !on)}
                        >
                          <Globe size={11} /> All Projects
                        </button>
                      );
                    })()}
                  <button
                    data-testid={`prompt-rename-${prompt.name}`}
                    className="rounded p-1 text-text-muted opacity-0 transition-opacity hover:text-text-primary group-hover:opacity-100"
                    title="Rename"
                    onClick={() =>
                      setRenaming({ name: prompt.name, scope: prompt.scope, value: prompt.name })
                    }
                  >
                    <Pencil size={13} />
                  </button>
                  <button
                    data-testid={`prompt-delete-${prompt.name}`}
                    className="rounded p-1 text-text-muted opacity-0 transition-opacity hover:text-[var(--color-role-error)] group-hover:opacity-100"
                    title="Delete"
                    onClick={() => void remove(prompt)}
                  >
                    <Trash2 size={13} />
                  </button>
                </>
              )}
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
