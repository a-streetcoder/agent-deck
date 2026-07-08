import { useCallback, useEffect, useState } from "react";
import { ShieldCheck } from "lucide-react";
import { cn } from "@/lib/cn";
import { SkeletonRows } from "../components/Skeleton.tsx";
import { useAppStore } from "../state/store.ts";

/**
 * Providers screen (native provider-login surface): the OAuth-capable model
 * providers pi knows about, with each one's sign-in status read from the global
 * ~/.pi/agent/auth.json, and a Log out action to disconnect a stored credential.
 * Interactive browser/device sign-in is a follow-up milestone; until then an
 * API key can be set on the Environment screen.
 */
interface ProviderEntry {
  id: string;
  name: string;
  configured: boolean;
  source?: string;
  label?: string;
  /** A credential stored in auth.json — the only state Log out can act on. */
  signedIn: boolean;
}

export function ProvidersScreen() {
  const setError = useAppStore((state) => state.setError);
  const resourcesVersion = useAppStore((state) => state.resourcesVersion);
  const [providers, setProviders] = useState<ProviderEntry[]>([]);
  const [loaded, setLoaded] = useState(false);

  const load = useCallback(async (): Promise<void> => {
    try {
      const response = await fetch("/runtime/providers");
      if (!response.ok) throw new Error(await response.text());
      const data = (await response.json()) as { providers: ProviderEntry[] };
      setProviders(data.providers);
    } catch (err) {
      setError(String(err));
    } finally {
      setLoaded(true);
    }
  }, [setError]);

  useEffect(() => {
    void load();
  }, [load, resourcesVersion]);

  const logout = async (provider: ProviderEntry): Promise<void> => {
    if (!confirm(`Disconnect ${provider.name}? You'll need to sign in again to use it.`)) return;
    try {
      const response = await fetch(`/runtime/providers/${encodeURIComponent(provider.id)}/logout`, {
        method: "POST",
      });
      if (!response.ok) throw new Error(await response.text());
      await load();
    } catch (err) {
      setError(String(err));
    }
  };

  return (
    <div className="min-h-0 flex-1 overflow-y-auto px-6 py-5" data-testid="providers-screen">
      <div className="mx-auto max-w-3xl">
        <div className="flex items-center gap-2 pb-1">
          <ShieldCheck size={16} className="text-text-secondary" aria-hidden />
          <h2
            className="text-base font-semibold text-text-primary"
            style={{ fontStretch: "expanded" }}
          >
            Providers
          </h2>
        </div>
        <p className="pb-3 text-xs text-text-muted">
          Model-provider sign-in status, read from your global auth. Set an API key on the
          Environment screen; interactive browser sign-in is coming to the app.
        </p>

        <div className="space-y-1.5" data-testid="provider-list">
          {!loaded ? <SkeletonRows count={3} /> : null}
          {providers.map((provider) => (
            <div
              key={provider.id}
              data-provider-id={provider.id}
              data-signed-in={provider.signedIn ? "true" : "false"}
              className="flex items-center gap-3 rounded-[14px] border border-border-subtle bg-surface px-3.5 py-2.5"
            >
              <div className="min-w-0 flex-1">
                <div
                  className="truncate text-sm font-medium text-text-primary"
                  style={{ fontStretch: "expanded" }}
                >
                  {provider.name}
                </div>
                <div className="truncate font-mono text-[11px] text-text-muted">{provider.id}</div>
              </div>
              <span
                data-testid={`provider-status-${provider.id}`}
                className={cn(
                  "rounded-capsule border px-2 py-0.5 text-[10px]",
                  provider.signedIn
                    ? "border-[var(--color-success)] text-[var(--color-success)]"
                    : provider.configured
                      ? "border-border-strong text-text-secondary"
                      : "border-border-strong text-text-muted",
                )}
                title={provider.label ?? provider.source ?? undefined}
              >
                {provider.signedIn
                  ? "Signed in"
                  : provider.configured
                    ? `Configured (${provider.source ?? "env"})`
                    : "Not connected"}
              </span>
              {provider.signedIn ? (
                <button
                  data-testid={`provider-logout-${provider.id}`}
                  className="rounded-capsule border border-border-strong px-2 py-0.5 text-xs text-text-secondary hover:text-[var(--color-role-error)]"
                  onClick={() => void logout(provider)}
                >
                  Log out
                </button>
              ) : null}
            </div>
          ))}
          {loaded && providers.length === 0 ? (
            <div className="py-8 text-center text-sm text-text-muted" data-testid="provider-empty">
              No OAuth-capable providers registered.
            </div>
          ) : null}
        </div>
      </div>
    </div>
  );
}
