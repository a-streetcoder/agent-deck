import { useEffect, useRef, useState } from "react";
import { ArrowUp, Brain, ChevronDown, Cpu, Square } from "lucide-react";
import { THINKING_LEVELS, type ThinkingLevel } from "@agent-deck/domain";
import { cn } from "@/lib/cn";

/**
 * Composer footer chips + send button, styled per the native composer footer
 * (PiAgentComposerFooterBar): glass capsule chips for model and thinking,
 * and a prominent circular send/stop button with a symbol swap.
 */

export interface PiModelInfo {
  provider: string;
  id: string;
  /** pi ModelInfo.reasoning — gates the thinking-level ladder (see ThinkingChip). */
  reasoning?: boolean;
}

export interface PiComposerState {
  provider?: string;
  modelId?: string;
  thinkingLevel: string;
}

export function chipClass(active = false): string {
  return cn(
    "flex items-center gap-1.5 rounded-capsule border px-2.5 py-1 text-xs font-medium transition-colors",
    active
      ? "border-[var(--color-selection-stroke)] bg-[var(--color-selection-fill)] text-text-primary"
      : "border-border-subtle bg-surface text-text-secondary hover:border-border-strong hover:text-text-primary",
  );
}

function useDismiss(onDismiss: () => void) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const onMouse = (event: MouseEvent): void => {
      if (ref.current && !ref.current.contains(event.target as Node)) onDismiss();
    };
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === "Escape") {
        onDismiss();
        // Return focus to the trigger (first button inside the wrapper).
        ref.current?.querySelector("button")?.focus();
      }
    };
    document.addEventListener("mousedown", onMouse);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onMouse);
      document.removeEventListener("keydown", onKey);
    };
  }, [onDismiss]);
  return ref;
}

export function ModelChip({
  state,
  models,
  onSelect,
}: {
  state: PiComposerState | null;
  models: PiModelInfo[];
  onSelect: (model: PiModelInfo) => void;
}) {
  const [open, setOpen] = useState(false);
  const ref = useDismiss(() => setOpen(false));

  const byProvider = new Map<string, PiModelInfo[]>();
  for (const model of models) {
    byProvider.set(model.provider, [...(byProvider.get(model.provider) ?? []), model]);
  }

  return (
    <div className="relative" ref={ref}>
      <button
        data-testid="model-chip"
        className={chipClass(open)}
        title="Model"
        aria-haspopup="listbox"
        aria-expanded={open}
        onClick={() => setOpen((v) => !v)}
      >
        <Cpu size={12} />
        <span className="max-w-[16ch] truncate" data-testid="model-chip-label">
          {state?.modelId ?? "model"}
        </span>
        <ChevronDown size={11} className="opacity-60" />
      </button>
      {open ? (
        <div
          data-testid="model-menu"
          role="listbox"
          aria-label="Model"
          className="absolute bottom-full left-0 z-20 mb-1.5 max-h-72 w-64 overflow-y-auto rounded-xl border border-border-strong bg-surface-elevated p-1.5 shadow-elevated"
        >
          {[...byProvider.entries()].map(([provider, providerModels]) => (
            <div key={provider}>
              <div className="px-2 pb-0.5 pt-1.5 text-[10px] font-semibold uppercase tracking-wider text-text-muted">
                {provider}
              </div>
              {providerModels.map((model) => (
                <button
                  key={`${model.provider}/${model.id}`}
                  data-testid={`model-option-${model.id}`}
                  className={cn(
                    "block w-full truncate rounded-md px-2 py-1 text-left text-xs",
                    model.id === state?.modelId && model.provider === state?.provider
                      ? "bg-[var(--color-selection-fill)] text-text-primary"
                      : "text-text-secondary hover:bg-[var(--color-hover-fill)]",
                  )}
                  onClick={() => {
                    setOpen(false);
                    onSelect(model);
                  }}
                >
                  {model.id}
                </button>
              ))}
            </div>
          ))}
          {models.length === 0 ? (
            <div className="px-2 py-2 text-xs text-text-muted">No models available.</div>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

export function ThinkingChip({
  state,
  levels = THINKING_LEVELS,
  onSelect,
}: {
  state: PiComposerState | null;
  /** Levels the current model supports; a non-reasoning model offers only "off". */
  levels?: readonly ThinkingLevel[];
  onSelect: (level: ThinkingLevel) => void;
}) {
  const [open, setOpen] = useState(false);
  const ref = useDismiss(() => setOpen(false));

  // Native `displayLevel`: when the active level isn't one the current model
  // supports (e.g. after switching to a non-reasoning model), surface it as
  // "{level} unavailable" rather than silently showing an unpickable value.
  const current = state?.thinkingLevel;
  const label =
    current == null
      ? "thinking"
      : (levels as readonly string[]).includes(current)
        ? current
        : `${current} unavailable`;

  return (
    <div className="relative" ref={ref}>
      <button
        data-testid="thinking-chip"
        className={chipClass(open)}
        title="Thinking level"
        aria-haspopup="listbox"
        aria-expanded={open}
        onClick={() => setOpen((v) => !v)}
      >
        <Brain size={12} />
        <span data-testid="thinking-chip-label">{label}</span>
        <ChevronDown size={11} className="opacity-60" />
      </button>
      {open ? (
        <div
          data-testid="thinking-menu"
          role="listbox"
          aria-label="Thinking level"
          className="absolute bottom-full left-0 z-20 mb-1.5 w-36 rounded-xl border border-border-strong bg-surface-elevated p-1.5 shadow-elevated"
        >
          {levels.map((level) => (
            <button
              key={level}
              data-testid={`thinking-option-${level}`}
              className={cn(
                "block w-full rounded-md px-2 py-1 text-left text-xs",
                level === state?.thinkingLevel
                  ? "bg-[var(--color-selection-fill)] text-text-primary"
                  : "text-text-secondary hover:bg-[var(--color-hover-fill)]",
              )}
              onClick={() => {
                setOpen(false);
                onSelect(level);
              }}
            >
              {level}
            </button>
          ))}
        </div>
      ) : null}
    </div>
  );
}

export function SendStopButton({
  running,
  disabled,
  onSend,
  onStop,
}: {
  running: boolean;
  disabled: boolean;
  onSend: () => void;
  onStop: () => void;
}) {
  return (
    <button
      data-testid={running ? "abort-button" : "send-button"}
      className={cn(
        "flex h-9 w-9 items-center justify-center rounded-full shadow-capsule transition-all",
        running ? "text-white" : "disabled:opacity-40",
      )}
      style={{
        background: running
          ? "var(--color-role-error)"
          : "linear-gradient(180deg, var(--color-brand-accent-bright), var(--color-brand-accent))",
        color: running ? "#fff" : "var(--color-accent-foreground)",
      }}
      disabled={!running && disabled}
      title={running ? "Stop" : "Send"}
      onClick={running ? onStop : onSend}
    >
      {running ? <Square size={13} fill="currentColor" /> : <ArrowUp size={16} strokeWidth={2.5} />}
    </button>
  );
}
