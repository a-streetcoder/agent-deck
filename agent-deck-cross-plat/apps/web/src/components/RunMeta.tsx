/**
 * Compact subagent run metadata (model · tokens · duration), shown on the deck
 * row and the Subagent transcript card — the cross-plat echo of the native
 * PiSubagentRunRecord metrics line. Renders nothing until any metric is present.
 */

export interface RunMetaProps {
  model?: string;
  inputTokens?: number;
  outputTokens?: number;
  durationMs?: number;
  className?: string;
}

function formatTokens(n: number): string {
  if (n < 1000) return String(n);
  return `${(n / 1000).toFixed(n < 10_000 ? 1 : 0)}k`;
}

function formatDuration(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  const s = ms / 1000;
  // Round to one decimal BEFORE the <60 check so e.g. 59.97s reads "1m 0s",
  // never "60.0s".
  const rounded = Math.round(s * 10) / 10;
  if (rounded < 60) return `${rounded.toFixed(1)}s`;
  const whole = Math.round(s);
  return `${Math.floor(whole / 60)}m ${whole % 60}s`;
}

export function RunMeta({ model, inputTokens, outputTokens, durationMs, className }: RunMetaProps) {
  const parts: string[] = [];
  if (model) parts.push(model);
  const tokens = (inputTokens ?? 0) + (outputTokens ?? 0);
  if (inputTokens !== undefined || outputTokens !== undefined)
    parts.push(`${formatTokens(tokens)} tok`);
  if (durationMs !== undefined) parts.push(formatDuration(durationMs));
  if (parts.length === 0) return null;

  return (
    <div
      className={`flex flex-wrap items-center gap-x-1.5 text-[10px] tabular-nums text-text-muted ${className ?? ""}`}
      data-testid="run-meta"
    >
      {parts.map((part, i) => (
        <span key={i} className="flex items-center gap-x-1.5">
          {i > 0 ? <span aria-hidden>·</span> : null}
          <span className={i === 0 && model ? "font-mono" : undefined}>{part}</span>
        </span>
      ))}
    </div>
  );
}
