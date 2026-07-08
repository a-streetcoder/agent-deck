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
  /** Where it was found — a standard pi dir (discovered) or the manual registry. */
  source?: "discovered" | "added";
  scope?: "global" | "project" | string;
  /** The app-bridge tool this extension re-registers, if any (kept out of launch). */
  bridgeConflict?: string | null;
}

/** An app-generated bridge (native "Agent Deck bridges" card) — read-only. */
interface AppBridge {
  id: string;
  displayName: string;
  summary: string;
  condition: string;
  toolNames: string[];
  active: boolean;
}

export function ExtensionsScreen() {
  const setError = useAppStore((state) => state.setError);
  const resourcesVersion = useAppStore((state) => state.resourcesVersion);
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const [extensions, setExtensions] = useState<ExtensionEntry[]>([]);
  const [bridges, setBridges] = useState<AppBridge[]>([]);
  const [adding, setAdding] = useState(false);
  const [draft, setDraft] = useState("");

  const load = useCallback(async (): Promise<void> => {
    try {
      // Pass the current project so project-scoped extensions are discovered too.
      const url = currentProjectId
        ? `/resources/extensions?projectId=${encodeURIComponent(currentProjectId)}`
        : "/resources/extensions";
      const response = await fetch(url);
      if (!response.ok) throw new Error(await response.text());
      const data = (await response.json()) as { extensions: ExtensionEntry[] };
      setExtensions(data.extensions);
    } catch (err) {
      setError(String(err));
    }
  }, [setError, currentProjectId]);

  useEffect(() => {
    void load();
  }, [load, resourcesVersion]);

  useEffect(() => {
    void (async () => {
      try {
        const response = await fetch("/runtime/bridges");
        if (!response.ok) return;
        const data = (await response.json()) as { bridges: AppBridge[] };
        setBridges(data.bridges);
      } catch {
        // Non-critical: the bridge inventory is informational only.
      }
    })();
  }, [resourcesVersion]);

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

        {bridges.length > 0 ? (
          <div className="mb-4" data-testid="app-bridges">
            <div className="pb-1.5 text-[11px] font-medium uppercase tracking-wide text-text-muted">
              Agent Deck bridges
            </div>
            <p className="pb-2 text-[11px] text-text-muted">
              Features Agent Deck injects into pi over its own bridge (not your files). Read-only.
            </p>
            <div className="space-y-1.5">
              {bridges.map((b) => (
                <div
                  key={b.id}
                  data-testid={`bridge-${b.id}`}
                  data-active={b.active ? "true" : "false"}
                  className={cn(
                    "rounded-[14px] border border-border-subtle bg-surface-subtle px-3.5 py-2.5",
                    !b.active && "opacity-55",
                  )}
                >
                  <div className="flex items-center gap-2">
                    <span
                      className="text-sm font-medium text-text-primary"
                      style={{ fontStretch: "expanded" }}
                    >
                      {b.displayName}
                    </span>
                    <span
                      data-testid={`bridge-state-${b.id}`}
                      className={cn(
                        "rounded-capsule border px-1.5 text-[10px]",
                        b.active
                          ? "border-[var(--color-success)] text-[var(--color-success)]"
                          : "border-border-subtle text-text-muted",
                      )}
                    >
                      {b.active ? "active" : "off"}
                    </span>
                  </div>
                  <div className="pt-0.5 text-[11px] text-text-muted">{b.summary}</div>
                  {b.toolNames.length > 0 ? (
                    <div className="truncate pt-0.5 font-mono text-[11px] text-text-muted">
                      {b.toolNames.join(", ")}
                    </div>
                  ) : (
                    <div className="pt-0.5 text-[11px] text-text-muted italic">{b.condition}</div>
                  )}
                </div>
              ))}
            </div>
          </div>
        ) : null}

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
                  <div className="flex items-center gap-2">
                    <span
                      className="truncate text-sm font-medium text-text-primary"
                      style={{ fontStretch: "expanded" }}
                    >
                      {ext.name}
                    </span>
                    {/* Where it came from (native scope/source label). */}
                    <span
                      data-testid={`extension-source-${ext.name}`}
                      className="rounded-capsule border border-border-subtle px-1.5 text-[10px] text-text-muted"
                    >
                      {ext.source === "added"
                        ? "added"
                        : `${ext.scope === "project" ? "project" : "global"} · discovered`}
                    </span>
                  </div>
                  <div className="truncate font-mono text-[11px] text-text-muted">{ext.path}</div>
                </div>
                {ext.bridgeConflict ? (
                  <span
                    data-testid={`extension-bridge-conflict-${ext.name}`}
                    title={`This extension registers "${ext.bridgeConflict}", a tool Agent Deck provides through its own bridge. The bridge takes precedence, so this extension is not loaded — rename its tool to use it.`}
                    className="flex items-center gap-1 rounded-capsule border border-[var(--color-role-error)] px-1.5 text-[10px] text-[var(--color-role-error)]"
                  >
                    <AlertTriangle size={10} /> shadowed by bridge
                  </span>
                ) : null}
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
                {/* Only registry entries can be removed; a discovered file is
                    managed on disk (disable to exclude it). */}
                {ext.source !== "discovered" ? (
                  <button
                    data-testid={`extension-remove-${ext.name}`}
                    className="rounded p-1 text-text-muted hover:text-[var(--color-role-error)]"
                    title="Remove"
                    onClick={() => void remove(ext)}
                  >
                    <Trash2 size={13} />
                  </button>
                ) : null}
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
