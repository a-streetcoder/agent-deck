import { memo } from "react";
import { cn } from "@/lib/cn";

/**
 * The +N/-N per-file / per-directory stat label (Slice 10), ported from
 * t3code's `chat/DiffStatLabel.tsx` (MIT): compact k/m/b counts, additions in
 * the diff-added tint, deletions in diff-removed, tabular numerals. The donor's
 * aligned/inline layouts survive; colors map to our tokens.
 */

export function hasNonZeroStat(stat: { additions: number; deletions: number }): boolean {
  return stat.additions > 0 || stat.deletions > 0;
}

function formatCompactDiffCount(value: number): string {
  if (value < 1000) return String(value);
  if (value < 1_000_000) {
    const k = value / 1000;
    return `${k < 10 ? k.toFixed(1).replace(/\.0$/, "") : Math.round(k)}k`;
  }
  if (value < 1_000_000_000) {
    const m = value / 1_000_000;
    return `${m < 10 ? m.toFixed(1).replace(/\.0$/, "") : Math.round(m)}m`;
  }
  const b = value / 1_000_000_000;
  return `${b < 10 ? b.toFixed(1).replace(/\.0$/, "") : Math.round(b)}b`;
}

export const DiffStatLabel = memo(function DiffStatLabel(props: {
  additions: number;
  deletions: number;
  className?: string;
  layout?: "aligned" | "inline";
}) {
  const { additions, deletions, className, layout = "aligned" } = props;
  return (
    <span
      className={cn(
        layout === "inline"
          ? "inline-flex items-center gap-1 align-middle tabular-nums"
          : "inline-grid grid-cols-[4ch_4ch] gap-1.5 text-right align-middle tabular-nums",
        className,
      )}
      data-testid="diff-stat"
    >
      <span className="font-mono text-[var(--color-diff-added)]">
        +{formatCompactDiffCount(additions)}
      </span>
      <span className="font-mono text-[var(--color-diff-removed)]">
        -{formatCompactDiffCount(deletions)}
      </span>
    </span>
  );
});
