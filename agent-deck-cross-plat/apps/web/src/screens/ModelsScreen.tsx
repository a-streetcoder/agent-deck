import { useCallback, useEffect, useRef, useState } from "react";
import { Check, Cpu, Eye, EyeOff, Sparkles } from "lucide-react";
import { cn } from "@/lib/cn";
import { useAppStore } from "../state/store.ts";
import { sendSetModel } from "../state/wsBridge.ts";

/**
 * Models screen (native Runtime → Models): the provider/model catalog pi
 * offers for the current session, grouped by provider with context-window /
 * reasoning / modality metadata. Selecting one sets the active session's model.
 */
interface CatalogModel {
  provider: string;
  id: string;
  name?: string;
  reasoning?: boolean;
  input?: string[];
  contextWindow?: number;
  maxTokens?: number;
  /** Hidden from the picker (app-level curation). */
  disabled?: boolean;
}

interface ActiveModel {
  provider: string;
  id: string;
}

function formatTokens(n?: number): string | null {
  if (!n) return null;
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(n % 1_000_000 ? 1 : 0)}M`;
  if (n >= 1000) return `${Math.round(n / 1000)}K`;
  return String(n);
}

export function ModelsScreen() {
  const session = useAppStore((state) => state.session);
  const setError = useAppStore((state) => state.setError);
  const sessionId = session?.id ?? null;
  const [models, setModels] = useState<CatalogModel[]>([]);
  const [active, setActive] = useState<ActiveModel | null>(null);
  // Guards a slow response for a previous session from clobbering the new one.
  const activeRef = useRef<string | null>(null);
  const reconcileTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  // pi's authoritative active model — used on load and to reconcile a select().
  const loadState = useCallback(async (id: string): Promise<void> => {
    try {
      const res = await fetch(`/sessions/${encodeURIComponent(id)}/state`);
      if (!res.ok || activeRef.current !== id) return;
      const { state } = (await res.json()) as {
        state: { model?: { provider: string; id: string } };
      };
      if (activeRef.current !== id) return;
      setActive(state.model ? { provider: state.model.provider, id: state.model.id } : null);
    } catch {
      // Transient; a later load reconciles.
    }
  }, []);

  const load = useCallback(
    async (id: string): Promise<void> => {
      activeRef.current = id;
      try {
        const res = await fetch(`/sessions/${encodeURIComponent(id)}/models`);
        if (res.ok && activeRef.current === id) {
          const data = (await res.json()) as { models: CatalogModel[] };
          setModels(data.models);
        }
        await loadState(id);
      } catch (err) {
        setError(String(err));
      }
    },
    [loadState, setError],
  );

  useEffect(() => {
    if (sessionId) void load(sessionId);
    return () => {
      if (reconcileTimer.current) clearTimeout(reconcileTimer.current);
    };
  }, [sessionId, load]);

  const select = (model: CatalogModel): void => {
    sendSetModel(model.provider, model.id);
    setActive({ provider: model.provider, id: model.id }); // optimistic
    // Reconcile against pi's actual state — set_model can reject a model.
    if (reconcileTimer.current) clearTimeout(reconcileTimer.current);
    reconcileTimer.current = setTimeout(() => {
      if (activeRef.current) void loadState(activeRef.current);
    }, 500);
  };

  const toggleDisabled = async (model: CatalogModel): Promise<void> => {
    await fetch("/runtime/models/disabled", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ provider: model.provider, id: model.id, disabled: !model.disabled }),
    });
    if (sessionId) void load(sessionId); // re-fetch so the row reflects the new state
  };

  const byProvider = new Map<string, CatalogModel[]>();
  for (const model of models) {
    byProvider.set(model.provider, [...(byProvider.get(model.provider) ?? []), model]);
  }

  return (
    <div className="min-h-0 flex-1 overflow-y-auto px-6 py-5" data-testid="models-screen">
      <div className="mx-auto max-w-3xl">
        <div className="flex items-center gap-2 pb-1">
          <Cpu size={16} className="text-text-secondary" aria-hidden />
          <h2
            className="text-base font-semibold text-text-primary"
            style={{ fontStretch: "expanded" }}
          >
            Models
          </h2>
        </div>
        <p className="pb-3 text-xs text-text-muted">
          Models available to the current session. Select one to make it active.
        </p>

        {!sessionId ? (
          <div className="py-8 text-center text-sm text-text-muted">
            Start a session to see its available models.
          </div>
        ) : models.length === 0 ? (
          <div className="py-8 text-center text-sm text-text-muted" data-testid="models-empty">
            No models available — check your provider configuration in Environment.
          </div>
        ) : (
          <div className="space-y-4">
            {[...byProvider.entries()].map(([provider, providerModels]) => (
              <div key={provider}>
                <div className="px-1 pb-1 text-[10px] font-semibold uppercase tracking-wider text-text-muted">
                  {provider}
                </div>
                <div className="space-y-1.5">
                  {providerModels.map((model) => {
                    const isActive = active?.provider === provider && active?.id === model.id;
                    const ctx = formatTokens(model.contextWindow);
                    return (
                      <div
                        key={model.id}
                        data-testid={`model-${model.id}`}
                        data-active={isActive}
                        data-disabled={model.disabled ? "true" : "false"}
                        className={cn(
                          "flex items-center gap-1 rounded-[14px] border transition-colors",
                          isActive
                            ? "border-[var(--color-brand-accent)] bg-[var(--color-selection-fill)]"
                            : "border-border-subtle bg-surface",
                          model.disabled && "opacity-45",
                        )}
                      >
                        <button
                          type="button"
                          data-testid={`model-select-${model.id}`}
                          disabled={model.disabled}
                          className={cn(
                            "flex min-w-0 flex-1 items-center gap-3 rounded-l-[14px] px-3.5 py-2.5 text-left",
                            !model.disabled && !isActive && "hover:bg-[var(--color-hover-fill)]",
                            model.disabled && "cursor-default",
                          )}
                          onClick={() => select(model)}
                        >
                          <div className="min-w-0 flex-1">
                            <div className="flex items-center gap-2">
                              <span
                                className="truncate text-sm font-medium text-text-primary"
                                style={{ fontStretch: "expanded" }}
                              >
                                {model.name ?? model.id}
                              </span>
                              {model.reasoning ? (
                                <span
                                  data-testid="reasoning-badge"
                                  className="flex items-center gap-0.5 rounded-capsule border border-border-subtle px-1.5 text-[10px] text-text-secondary"
                                >
                                  <Sparkles size={9} aria-hidden /> reasoning
                                </span>
                              ) : null}
                            </div>
                            <div className="truncate font-mono text-[11px] text-text-muted">
                              {model.id}
                            </div>
                          </div>
                          <div className="flex shrink-0 items-center gap-3 text-[11px] text-text-muted">
                            {ctx ? <span title="Context window">{ctx} ctx</span> : null}
                            {model.input?.includes("image") ? <span>image</span> : null}
                            {isActive ? (
                              <Check size={15} style={{ color: "var(--color-brand-accent)" }} />
                            ) : null}
                          </div>
                        </button>
                        <button
                          type="button"
                          data-testid={`model-toggle-${model.id}`}
                          aria-label={model.disabled ? "Enable model" : "Disable model"}
                          title={model.disabled ? "Show in picker" : "Hide from picker"}
                          className="shrink-0 rounded-r-[14px] px-3 py-2.5 text-text-muted hover:bg-[var(--color-hover-fill)] hover:text-text-primary"
                          onClick={() => void toggleDisabled(model)}
                        >
                          {model.disabled ? <EyeOff size={15} /> : <Eye size={15} />}
                        </button>
                      </div>
                    );
                  })}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
