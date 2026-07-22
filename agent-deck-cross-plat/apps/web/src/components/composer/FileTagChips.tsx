import { FileText, X } from "lucide-react";
import type { FileMention } from "../../lib/fileMentions.ts";

/**
 * Slice 17 — file tag chips. Surfaces the composer's `@`-file mentions as
 * removable chips (donor FileTagChip), derived purely from the draft text. The
 * literal `@path` tokens stay in the prompt (existing @-mention behavior); a chip
 * is just a view over them, and removing a chip edits the draft. Ported from the
 * donor FileTagChip, restyled onto our composer chip tokens.
 */

/** Show the basename in the chip; the full path is the title/tooltip. Splits on
 * both separators — the file search returns OS-native paths (backslashes on
 * Windows), so a POSIX-only split would leave the whole path in the label. */
function basename(path: string): string {
  const trimmed = path.replace(/[/\\]+$/, "");
  const idx = Math.max(trimmed.lastIndexOf("/"), trimmed.lastIndexOf("\\"));
  return idx >= 0 ? trimmed.slice(idx + 1) : trimmed;
}

export function FileTagChips({
  mentions,
  onRemove,
}: {
  mentions: readonly FileMention[];
  onRemove: (start: number) => void;
}) {
  if (mentions.length === 0) return null;
  return (
    <div className="flex flex-wrap gap-1.5 px-3 pt-3" data-testid="file-tag-chips">
      {mentions.map((mention) => (
        <span
          key={`${mention.start}:${mention.path}`}
          data-testid="file-tag-chip"
          data-path={mention.path}
          title={mention.path}
          className="flex items-center gap-1.5 rounded-lg border border-border-strong bg-surface px-2 py-1 text-xs text-text-secondary"
        >
          <FileText size={12} className="shrink-0 text-text-muted" />
          <span className="max-w-[18ch] truncate font-mono">{basename(mention.path)}</span>
          <button
            type="button"
            className="text-text-muted hover:text-[var(--color-role-error)]"
            aria-label={`Remove ${mention.path}`}
            data-testid="file-tag-remove"
            onClick={() => onRemove(mention.start)}
          >
            <X size={12} />
          </button>
        </span>
      ))}
    </div>
  );
}
