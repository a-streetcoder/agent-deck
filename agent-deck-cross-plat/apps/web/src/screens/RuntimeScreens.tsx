import { useEffect, useState } from "react";
import { CheckCircle2, Key, Stethoscope, TriangleAlert, XCircle } from "lucide-react";
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
}

export function EnvironmentScreen() {
  const currentProjectId = useAppStore((state) => state.currentProjectId);
  const resourcesVersion = useAppStore((state) => state.resourcesVersion);
  const [entries, setEntries] = useState<EnvEntry[]>([]);

  useEffect(() => {
    const query = currentProjectId ? `?projectId=${encodeURIComponent(currentProjectId)}` : "";
    let cancelled = false;
    void fetch(`/runtime/env${query}`)
      .then((response) => response.json())
      .then((data: { entries: EnvEntry[] }) => {
        if (!cancelled) setEntries(data.entries);
      });
    return () => {
      cancelled = true;
    };
  }, [currentProjectId, resourcesVersion]);

  return (
    <div className="min-h-0 flex-1 overflow-y-auto px-6 py-5" data-testid="environment-screen">
      <div className="rounded-2xl border border-border-subtle bg-surface-elevated p-4">
        <div className="flex items-center gap-2 pb-1">
          <Key size={16} className="text-text-secondary" />
          <h2
            className="text-base font-semibold text-text-primary"
            style={{ fontStretch: "expanded" }}
          >
            Environment
          </h2>
        </div>
        <p className="pb-3 text-xs text-text-muted">
          Variables from ~/.pi/agent/.env and this project's .pi/.env. Values are masked — this is a
          read-only presence inspector.
        </p>
        <div className="space-y-1">
          {entries.map((entry) => (
            <div
              key={`${entry.scope}:${entry.key}`}
              className="flex items-center gap-3 rounded-lg border border-border-subtle bg-surface px-3 py-1.5"
              data-testid="env-row"
              data-env-key={entry.key}
              style={entry.overridden ? { opacity: 0.55 } : undefined}
            >
              <span className="min-w-0 flex-1 truncate font-mono text-sm text-text-primary">
                {entry.key}
              </span>
              <span className="font-mono text-xs text-text-muted">{entry.masked || "(empty)"}</span>
              <ScopeChip scope={entry.scope} />
              {entry.overridden ? (
                <span className="text-[10px] text-text-muted">overridden</span>
              ) : null}
            </div>
          ))}
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
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
