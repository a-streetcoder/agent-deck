import { forwardRef, useState, type ReactNode } from "react";
import { ChevronDown, ChevronRight, Diff, Globe, Plug, Terminal } from "lucide-react";

import { cn } from "@/lib/cn";
import { AppLabelTag, type AppLabelTagVariant } from "@/design-system/components/AppLabelTag";

/**
 * Tool run lifecycle phases — picks the status-pill variant and the
 * header tint.
 */
export type ToolGroupStatus = "starting" | "running" | "result" | "failed";

/**
 * Sub-card transport — drives the leading glyph and a `data-variant`
 * mark consumed by the transcript dispatch.
 */
export type ToolGroupVariant = "generic" | "web" | "diff" | "mcp";

export interface ToolGroupCardProps {
  /** Tool name (`bash`, `Edit`, `web_search`, …). */
  name: string;
  /** Run lifecycle phase. */
  status: ToolGroupStatus;
  /** Optional call count (header chip). */
  callCount?: number;
  /** Optional duration string ("240ms"). */
  duration?: string;
  /** Expandable body. */
  body?: ReactNode;
  /** Open by default — used for streaming tool calls. */
  defaultExpanded?: boolean;
  /** Card variant — picks the leading icon and slot styling. */
  variant?: ToolGroupVariant;
  className?: string;
}

const STATUS_LABEL: Record<ToolGroupStatus, string> = {
  starting: "starting",
  running: "running",
  result: "result",
  failed: "failed",
};

const STATUS_TAG: Record<ToolGroupStatus, AppLabelTagVariant> = {
  starting: "info",
  running: "info",
  result: "success",
  failed: "error",
};

const VARIANT_ICON: Record<ToolGroupVariant, (props: { className: string }) => ReactNode> = {
  generic: ({ className }) => <Terminal className={className} aria-hidden="true" />,
  web: ({ className }) => <Globe className={className} aria-hidden="true" />,
  diff: ({ className }) => <Diff className={className} aria-hidden="true" />,
  mcp: ({ className }) => <Plug className={className} aria-hidden="true" />,
};

/**
 * Tool-group transcript card. Mirrors `PiAgentNativeToolGroupView` /
 * `PiAgentToolTranscriptView`. The header is always visible; the body
 * collapses to a single line of metadata when closed and expands to a
 * scrollable inset region.
 *
 * Variant-specific sub-cards (Web list, Diff inline, MCP response
 * viewer) are passed in via `body` — this component owns the chrome,
 * expand toggle, and status pill only.
 */
export const ToolGroupCard = forwardRef<HTMLDivElement, ToolGroupCardProps>(function ToolGroupCard(
  {
    name,
    status,
    callCount,
    duration,
    body,
    defaultExpanded = false,
    variant = "generic",
    className,
  },
  ref,
) {
  const [open, setOpen] = useState(defaultExpanded);
  const Icon = VARIANT_ICON[variant];

  return (
    <div
      ref={ref}
      data-testid="tool-group-card"
      data-status={status}
      data-variant={variant}
      className={cn(
        "rounded-xl border border-border-subtle bg-surface-elevated",
        "flex flex-col",
        className,
      )}
    >
      <button
        type="button"
        aria-expanded={open}
        onClick={() => setOpen((prev) => !prev)}
        className={cn(
          "flex w-full items-center gap-2 px-3 py-2 text-left",
          "rounded-xl focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40",
          body ? "hover:bg-[var(--color-hover-fill)]" : "cursor-default",
        )}
      >
        <Icon className="h-4 w-4 shrink-0 text-text-secondary" />
        <span className="font-mono text-[12px] font-semibold text-text-primary truncate">
          {name}
        </span>
        <AppLabelTag variant={STATUS_TAG[status]} className="shrink-0">
          {STATUS_LABEL[status]}
        </AppLabelTag>
        {typeof callCount === "number" && callCount > 0 ? (
          <span className="shrink-0 text-[11px] text-text-muted">
            {callCount} {callCount === 1 ? "call" : "calls"}
          </span>
        ) : null}
        <span className="flex-1" />
        {duration ? (
          <span className="shrink-0 text-[11px] font-mono text-text-muted">{duration}</span>
        ) : null}
        {body ? (
          open ? (
            <ChevronDown className="h-3.5 w-3.5 shrink-0 text-text-muted" aria-hidden="true" />
          ) : (
            <ChevronRight className="h-3.5 w-3.5 shrink-0 text-text-muted" aria-hidden="true" />
          )
        ) : null}
      </button>
      {open && body ? (
        <div
          data-testid="tool-group-card-body"
          data-variant={variant}
          className="border-t border-border-subtle px-3 py-2 text-[12px]"
        >
          {body}
        </div>
      ) : null}
    </div>
  );
});

export default ToolGroupCard;
