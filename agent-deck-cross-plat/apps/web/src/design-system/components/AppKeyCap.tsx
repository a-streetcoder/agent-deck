import { Fragment, type ReactNode } from "react";
import { cn } from "../../lib/cn";

export interface AppKeyCapProps {
  /** A single key label (string or ReactNode). */
  children?: ReactNode;
  /** An ordered list of keys; rendered as caps joined by "+". */
  keys?: string[];
  className?: string;
}

function keyLabel(node: ReactNode): string {
  if (typeof node === "string") return node;
  if (typeof node === "number") return String(node);
  return "";
}

interface CapProps {
  children: ReactNode;
}

function Cap({ children }: CapProps) {
  const label = keyLabel(children);
  const length: "single" | "multi" = label.length <= 1 ? "single" : "multi";
  return (
    <kbd
      data-length={length}
      className={cn(
        "inline-flex min-h-[22px] min-w-[22px] items-center justify-center",
        "rounded-md border border-border-subtle bg-[var(--color-surface-subtle)]",
        "font-mono font-semibold text-text-primary",
        "shadow-[0_1px_0_rgba(0,0,0,0.08)]",
        length === "single" ? "px-0 text-xs" : "px-1.5 text-[10px]",
      )}
    >
      {children}
    </kbd>
  );
}

/**
 * Keyboard-shortcut "cap" matching the macOS `AppKeyCap` primitive:
 * 22pt min square, 6pt corner radius, subtle bottom shadow.
 *
 * Multi-key shortcuts (e.g. `["Cmd", "K"]`) are rendered as a row of caps
 * joined by a "+" separator. Single-character labels get a larger font and
 * tighter padding; multi-character labels (Cmd, Shift) shrink the font and
 * add horizontal padding to keep widths balanced.
 */
export function AppKeyCap({ children, keys, className }: AppKeyCapProps) {
  const list: ReactNode[] =
    keys !== undefined && keys.length > 0
      ? keys
      : children !== undefined && children !== null
        ? [children]
        : [];

  if (list.length === 0) return null;

  return (
    <span className={cn("inline-flex items-center gap-1 align-middle", className)}>
      {list.map((key, index) => (
        <Fragment key={index}>
          {index > 0 ? (
            <span aria-hidden className="text-xs text-text-muted">
              +
            </span>
          ) : null}
          <Cap>{key}</Cap>
        </Fragment>
      ))}
    </span>
  );
}

export default AppKeyCap;
