import { useCallback, useEffect, useState } from "react";
import { AlertTriangle, Plug, Plus, Trash2 } from "lucide-react";
import { conflictingExtensionNames } from "@agent-deck/domain";
import { cn } from "@/lib/cn";
import { useAppStore } from "../state/store.ts";

/**
 * Extensions screen (native Runtime → Extensions): user-added pi extension
 * files (.ts/.js) that load into every new session via --extension. Toggle
 * one off to exclude it without forgetting the entry.
 */
interface ExtensionEntry {
  path: string;
  name: string;
  exists: boolean;
  disabled: boolean;
}

export function ExtensionsScreen() {
  const setError = useAppStore((state) => state.setError);
  const resourcesVersion = useAppStore((state) => state.resourcesVersion);
  const [extensions, setExtensions] = useState<ExtensionEntry[]>([]);
  const [adding, setAdding] = useState(false);
  const [draft, setDraft] = useState("");

  const load = useCallback(async (): Promise<void> => {
    try {
      const response = await fetch("/resources/extensions");
      if (!response.ok) throw new Error(await response.text());
      const data = (await response.json()) as { extensions: ExtensionEntry[] };
      setExtensions(data.extensions);
    } catch (err) {
      setError(String(err));
    }
  }, [setError]);

  useEffect(() => {
    void load();
  }, [load, resourcesVersion]);

  const add = async (): Promise<void> => {
    const path = draft.trim();
    if (!path) return;
    try {
      const response = await fetch("/resources/extensions", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ path }),
      });
      if (!response.ok) throw new Error(await response.text());
      setDraft("");
      setAdding(false);
      await load();
    } catch (err) {
      setError(String(err));
    }
  };

  const toggle = async (ext: ExtensionEntry): Promise<void> => {
    await fetch("/resources/extensions/disabled", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path: ext.path, disabled: !ext.disabled }),
    }).catch(() => {});
    await load();
  };

  const remove = async (ext: ExtensionEntry): Promise<void> => {
    await fetch("/resources/extensions", {
      method: "DELETE",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path: ext.path }),
    }).catch(() => {});
    await load();
  };

  // Names loaded by 2+ enabled extensions — pi would load duplicates (§16.2).
  const conflicts = conflictingExtensionNames(extensions);

  return (
    <div className="min-h-0 flex-1 overflow-y-auto px-6 py-5" data-testid="extensions-screen">
      <div className="mx-auto max-w-3xl">
        <div className="flex items-center justify-between pb-1">
          <div className="flex items-center gap-2">
            <Plug size={16} className="text-text-secondary" aria-hidden />
            <h2
              className="text-base font-semibold text-text-primary"
              style={{ fontStretch: "expanded" }}
            >
              Extensions
            </h2>
          </div>
          <button
            data-testid="extension-add"
            className="flex items-center gap-1.5 rounded-capsule px-3 py-1 text-xs font-medium shadow-capsule"
            style={{
              background:
                "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
              color: "var(--color-accent-foreground)",
            }}
            onClick={() => setAdding((v) => !v)}
          >
            <Plus size={13} /> Add extension
          </button>
        </div>
        <p className="pb-3 text-xs text-text-muted">
          pi extension files loaded into every new session. Disabled ones stay listed but don&apos;t
          load.
        </p>

        {adding ? (
          <div className="mb-3 flex gap-2">
            <input
              autoFocus
              data-testid="extension-path"
              className="min-w-0 flex-1 rounded-lg border border-border-strong bg-surface px-2.5 py-1.5 font-mono text-xs text-text-primary outline-none focus:border-accent"
              placeholder="/path/to/extension.ts"
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") void add();
                if (e.key === "Escape") setAdding(false);
              }}
            />
            <button
              data-testid="extension-add-confirm"
              className="rounded-capsule px-3 py-1.5 text-xs font-medium shadow-capsule disabled:opacity-40"
              style={{
                background:
                  "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
                color: "var(--color-accent-foreground)",
              }}
              disabled={!draft.trim()}
              onClick={() => void add()}
            >
              Add
            </button>
          </div>
        ) : null}

        <div className="space-y-1.5" data-testid="extension-list">
          {extensions.map((ext) => {
            const conflicting = !ext.disabled && conflicts.has(ext.name);
            return (
              <div
                key={ext.path}
                data-extension-name={ext.name}
                data-conflict={conflicting ? "true" : "false"}
                className={cn(
                  "flex items-center gap-3 rounded-[14px] border bg-surface px-3.5 py-2.5",
                  conflicting ? "border-[var(--color-warning)]" : "border-border-subtle",
                  ext.disabled && "opacity-55",
                )}
              >
                <div className="min-w-0 flex-1">
                  <div
                    className="truncate text-sm font-medium text-text-primary"
                    style={{ fontStretch: "expanded" }}
                  >
                    {ext.name}
                  </div>
                  <div className="truncate font-mono text-[11px] text-text-muted">{ext.path}</div>
                </div>
                {conflicting ? (
                  <span
                    data-testid="extension-conflict"
                    title="Another enabled extension has the same filename. pi loads both (it keys by path), but two extensions sharing a name is usually a mistake — disable or remove one."
                    className="flex items-center gap-1 rounded-capsule border border-[var(--color-warning)] px-1.5 text-[10px] text-[var(--color-warning)]"
                  >
                    <AlertTriangle size={10} /> conflict
                  </span>
                ) : null}
                {!ext.exists ? (
                  <span className="rounded-capsule border border-[var(--color-role-error)] px-1.5 text-[10px] text-[var(--color-role-error)]">
                    missing
                  </span>
                ) : null}
                <button
                  data-testid={`extension-toggle-${ext.name}`}
                  data-enabled={!ext.disabled}
                  className="rounded-capsule border border-border-strong px-2 py-0.5 text-xs text-text-secondary hover:text-text-primary"
                  onClick={() => void toggle(ext)}
                >
                  {ext.disabled ? "Enable" : "Disable"}
                </button>
                <button
                  data-testid={`extension-remove-${ext.name}`}
                  className="rounded p-1 text-text-muted hover:text-[var(--color-role-error)]"
                  title="Remove"
                  onClick={() => void remove(ext)}
                >
                  <Trash2 size={13} />
                </button>
              </div>
            );
          })}
          {extensions.length === 0 && !adding ? (
            <div className="py-8 text-center text-sm text-text-muted">
              No extensions added. Point at a pi extension file to load it into sessions.
            </div>
          ) : null}
        </div>
      </div>
    </div>
  );
}
