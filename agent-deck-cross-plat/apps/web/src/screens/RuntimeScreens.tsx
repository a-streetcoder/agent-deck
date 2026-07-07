import { useCallback, useEffect, useRef, useState } from "react";
import {
  Check,
  CheckCircle2,
  Copy,
  Key,
  Pencil,
  Plus,
  Stethoscope,
  TriangleAlert,
  Trash2,
  XCircle,
} from "lucide-react";
import { cn } from "@/lib/cn";
import { useAppStore } from "../state/store.ts";
import { ScopeChip } from "../components/ScopeChip.tsx";

/**
 * Runtime screens (native Runtime section): a read-only Environment inspector
 * (masked .env values) and a Doctor health probe. Both are diagnostic and
 * never expose secrets.
 */

interface EnvEntry {
  key: string;
  masked: string;
  scope: "global" | "project";
  overridden: boolean;
  source: string;
}

type EnvScope = "global" | "project";

export function EnvironmentScreen() {
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const resourcesVersion = useAppStore((state) => state.resourcesVersion);
  const setError = useAppStore((state) => state.setError);
  const [entries, setEntries] = useState<EnvEntry[]>([]);
  const [editing, setEditing] = useState<{ scope: EnvScope; key: string } | null>(null);
  const [draftValue, setDraftValue] = useState("");
  const [adding, setAdding] = useState(false);
  const [newKey, setNewKey] = useState("");
  const [newValue, setNewValue] = useState("");
  const [newScope, setNewScope] = useState<EnvScope>("global");

  const refresh = useCallback(async (): Promise<void> => {
    const query = currentProjectId ? `?projectId=${encodeURIComponent(currentProjectId)}` : "";
    const response = await fetch(`/runtime/env${query}`);
    if (response.ok) setEntries(((await response.json()) as { entries: EnvEntry[] }).entries);
  }, [currentProjectId]);

  useEffect(() => {
    void refresh();
  }, [refresh, resourcesVersion]);

  const writeVar = async (scope: EnvScope, key: string, value: string): Promise<void> => {
    const response = await fetch("/runtime/env", {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ projectId: currentProjectId ?? undefined, scope, key, value }),
    });
    if (!response.ok) setError(await response.text());
    await refresh();
  };

  const deleteVar = async (scope: EnvScope, key: string): Promise<void> => {
    const response = await fetch("/runtime/env", {
      method: "DELETE",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ projectId: currentProjectId ?? undefined, scope, key }),
    });
    if (!response.ok) setError(await response.text());
    await refresh();
  };

  return (
    <div className="min-h-0 flex-1 overflow-y-auto px-6 py-5" data-testid="environment-screen">
      <div className="rounded-2xl border border-border-subtle bg-surface-elevated p-4">
        <div className="flex items-center justify-between pb-1">
          <div className="flex items-center gap-2">
            <Key size={16} className="text-text-secondary" />
            <h2
              className="text-base font-semibold text-text-primary"
              style={{ fontStretch: "expanded" }}
            >
              Environment
            </h2>
          </div>
          <button
            data-testid="env-add"
            className="flex h-7 w-7 items-center justify-center rounded-full shadow-capsule"
            style={{
              background:
                "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
              color: "var(--color-accent-foreground)",
            }}
            title="Add variable"
            onClick={() => {
              setAdding((v) => !v);
              setNewScope(currentProjectId ? "project" : "global");
            }}
          >
            <Plus size={14} />
          </button>
        </div>
        <p className="pb-3 text-xs text-text-muted">
          Variables from ~/.pi/agent/.env and this project's .pi/.env. Values are masked; editing
          replaces the whole value.
        </p>

        {adding ? (
          <div className="mb-3 flex flex-wrap items-center gap-2 rounded-lg border border-border-strong bg-surface p-2">
            <input
              data-testid="env-new-key"
              className="min-w-[10ch] flex-1 rounded border border-border-strong bg-surface px-2 py-1 font-mono text-xs text-text-primary outline-none focus:border-accent"
              placeholder="KEY"
              value={newKey}
              onChange={(e) => setNewKey(e.target.value)}
            />
            <input
              data-testid="env-new-value"
              className="min-w-[12ch] flex-1 rounded border border-border-strong bg-surface px-2 py-1 font-mono text-xs text-text-primary outline-none focus:border-accent"
              placeholder="value"
              value={newValue}
              onChange={(e) => setNewValue(e.target.value)}
            />
            <select
              data-testid="env-new-scope"
              className="rounded border border-border-strong bg-surface px-2 py-1 text-xs text-text-primary"
              value={newScope}
              onChange={(e) => setNewScope(e.target.value as EnvScope)}
            >
              <option value="global">global</option>
              {currentProjectId ? <option value="project">project</option> : null}
            </select>
            <button
              data-testid="env-new-save"
              className="rounded-capsule px-3 py-1 text-xs font-medium shadow-capsule disabled:opacity-40"
              style={{
                background:
                  "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
                color: "var(--color-accent-foreground)",
              }}
              disabled={!/^[A-Za-z_][A-Za-z0-9_]*$/.test(newKey)}
              onClick={() =>
                void writeVar(newScope, newKey, newValue).then(() => {
                  setNewKey("");
                  setNewValue("");
                  setAdding(false);
                })
              }
            >
              Add
            </button>
          </div>
        ) : null}

        <div className="space-y-1">
          {entries.map((entry) => {
            const isEditing = editing?.scope === entry.scope && editing.key === entry.key;
            return (
              <div
                key={`${entry.scope}:${entry.key}`}
                className={cn(
                  "flex items-center gap-3 rounded-lg border border-border-subtle bg-surface px-3 py-1.5",
                  entry.overridden && "opacity-55",
                )}
                data-testid="env-row"
                data-env-key={entry.key}
                data-env-scope={entry.scope}
              >
                <div className="min-w-0 flex-1">
                  <div className="truncate font-mono text-sm text-text-primary">{entry.key}</div>
                  <div
                    className="truncate font-mono text-[10px] text-text-muted"
                    data-testid="env-source"
                    title={entry.source}
                  >
                    {entry.source}
                  </div>
                </div>
                {isEditing ? (
                  <input
                    autoFocus
                    data-testid={`env-edit-input-${entry.key}`}
                    className="w-40 rounded border border-border-strong bg-surface px-2 py-0.5 font-mono text-xs text-text-primary outline-none focus:border-accent"
                    placeholder="new value"
                    value={draftValue}
                    onChange={(e) => setDraftValue(e.target.value)}
                    onKeyDown={(e) => {
                      if (e.key === "Enter") {
                        void writeVar(entry.scope, entry.key, draftValue).then(() =>
                          setEditing(null),
                        );
                      }
                      if (e.key === "Escape") setEditing(null);
                    }}
                    onBlur={() => setEditing(null)}
                  />
                ) : (
                  <span className="font-mono text-xs text-text-muted">
                    {entry.masked || "(empty)"}
                  </span>
                )}
                <ScopeChip scope={entry.scope} />
                {entry.overridden ? (
                  <span className="text-[10px] text-text-muted">overridden</span>
                ) : null}
                <button
                  data-testid={`env-edit-${entry.key}`}
                  className="rounded p-1 text-text-muted hover:text-text-primary"
                  title="Set value"
                  onClick={() => {
                    setDraftValue("");
                    setEditing({ scope: entry.scope, key: entry.key });
                  }}
                >
                  <Pencil size={12} />
                </button>
                <button
                  data-testid={`env-delete-${entry.key}`}
                  className="rounded p-1 text-text-muted hover:text-[var(--color-role-error)]"
                  title="Delete"
                  onClick={() => {
                    if (confirm(`Delete environment key "${entry.key}"?`)) {
                      void deleteVar(entry.scope, entry.key);
                    }
                  }}
                >
                  <Trash2 size={12} />
                </button>
              </div>
            );
          })}
          {entries.length === 0 ? (
            <div className="py-6 text-center text-sm text-text-muted">
              No environment variables found.
            </div>
          ) : null}
        </div>
      </div>
    </div>
  );
}

interface HealthCheck {
  id: string;
  label: string;
  status: "ok" | "warn" | "error";
  detail: string;
  fixCommand?: string;
}

/** Copy a check's suggested fix command; flips to "Copied" briefly (native Doctor Fix). */
function CopyFixButton({ command }: { command: string }) {
  const [copied, setCopied] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  // Clear a pending flip-back if the button unmounts (Doctor navigated away / refreshed).
  useEffect(() => {
    return () => {
      if (timer.current) clearTimeout(timer.current);
    };
  }, []);

  const copy = (): void => {
    let promise: Promise<void> | undefined;
    try {
      promise = navigator.clipboard?.writeText(command);
    } catch {
      // A present-but-throwing clipboard implementation — treat as unavailable.
      return;
    }
    void promise?.then(
      () => {
        setCopied(true);
        if (timer.current) clearTimeout(timer.current);
        timer.current = setTimeout(() => setCopied(false), 1500);
      },
      () => {},
    );
  };

  return (
    <button
      data-testid="doctor-fix-copy"
      data-fix-command={command}
      title={`Copy: ${command}`}
      className="flex shrink-0 items-center gap-1 rounded-capsule border border-border-strong px-2 py-0.5 font-mono text-[10px] text-text-secondary hover:text-text-primary"
      onClick={copy}
    >
      {copied ? <Check size={11} /> : <Copy size={11} />}
      {copied ? "Copied" : "Copy fix"}
    </button>
  );
}

const STATUS_ICON = {
  ok: { Icon: CheckCircle2, color: "var(--color-success)" },
  warn: { Icon: TriangleAlert, color: "var(--color-warning)" },
  error: { Icon: XCircle, color: "var(--color-role-error)" },
} as const;

export function DoctorScreen() {
  const [checks, setChecks] = useState<HealthCheck[]>([]);
  const [loading, setLoading] = useState(true);

  const refresh = (): void => {
    setLoading(true);
    void fetch("/runtime/doctor")
      .then((response) => response.json())
      .then((data: { report: { checks: HealthCheck[] } }) => setChecks(data.report.checks))
      .finally(() => setLoading(false));
  };

  useEffect(refresh, []);

  return (
    <div className="min-h-0 flex-1 overflow-y-auto px-6 py-5" data-testid="doctor-screen">
      <div className="rounded-2xl border border-border-subtle bg-surface-elevated p-4">
        <div className="flex items-center justify-between pb-1">
          <div className="flex items-center gap-2">
            <Stethoscope size={16} className="text-text-secondary" />
            <h2
              className="text-base font-semibold text-text-primary"
              style={{ fontStretch: "expanded" }}
            >
              Doctor
            </h2>
          </div>
          <button
            data-testid="doctor-refresh"
            className="rounded-capsule border border-border-strong px-3 py-1 text-xs text-text-secondary hover:text-text-primary disabled:opacity-40"
            disabled={loading}
            onClick={refresh}
          >
            {loading ? "Checking…" : "Re-check"}
          </button>
        </div>
        <p className="pb-3 text-xs text-text-muted">
          Environment health for the pi runtime this app drives.
        </p>
        <div className="space-y-2">
          {checks.map((check) => {
            const { Icon, color } = STATUS_ICON[check.status];
            return (
              <div
                key={check.id}
                className="flex items-start gap-3 rounded-lg border border-border-subtle bg-surface px-3 py-2.5"
                data-testid="doctor-check"
                data-check-id={check.id}
                data-check-status={check.status}
              >
                <Icon size={16} style={{ color }} className="mt-0.5 shrink-0" />
                <div className="min-w-0 flex-1">
                  <div className="text-sm font-medium text-text-primary">{check.label}</div>
                  <div className="break-words font-mono text-xs text-text-muted">
                    {check.detail}
                  </div>
                </div>
                {check.fixCommand ? <CopyFixButton command={check.fixCommand} /> : null}
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
