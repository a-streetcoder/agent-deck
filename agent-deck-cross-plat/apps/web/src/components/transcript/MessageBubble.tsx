import { forwardRef, type ReactNode } from "react";

import { cn } from "@/lib/cn";
import { MarkdownDocument } from "@/design-system/markdown/MarkdownDocument";
import { BrandIcon } from "../BrandIcon.tsx";

/**
 * Role kinds supported by the message bubble.
 *
 * Mirrors the macOS `PiAgentTranscriptCard` role palette. `status`,
 * `tool`, `error`, etc. each have their own dedicated card components
 * — MessageBubble itself is the canonical user/assistant/thinking
 * surface and accepts those rarer roles as a fallback styling pass.
 */
export type MessageBubbleRole =
  | "user"
  | "assistant"
  | "thinking"
  | "tool"
  | "status"
  | "error"
  | "stderr"
  | "raw";

/**
 * Minimal inline-chip shape rendered inside a user bubble (paste
 * marker, attached file, attached image, etc.). The full preview popover
 * lives in its own component — this is just the label rendered inside
 * the bubble itself.
 */
export interface MessageBubbleAttachment {
  id: string;
  kind: "paste" | "file" | "folder" | "image" | "issue" | "skill" | "command";
  label: string;
}

export interface MessageBubbleProps {
  /** Role tint and label resolution key. */
  role: MessageBubbleRole;
  /** Header label override. Defaults to a role-derived string. */
  headerLabel?: ReactNode;
  /** Markdown source for the body. */
  text?: string;
  /** Optional inline attachment chips (user side). */
  attachments?: MessageBubbleAttachment[];
  /** Trailing slot — typically a timestamp or status badge. */
  trailing?: ReactNode;
  className?: string;
}

const ROLE_HEADER_LABEL: Record<MessageBubbleRole, string> = {
  user: "You",
  assistant: "Pi",
  thinking: "Thinking",
  tool: "Tool",
  status: "Status",
  error: "Error",
  stderr: "stderr",
  raw: "Raw",
};

/**
 * Role-tinted tailwind chrome — fill + stroke at low opacity so the
 * bubble reads as a soft tinted card rather than a solid block. Tracks
 * the macOS `roleFillOpacity` / `roleStrokeOpacity` constants.
 */
const ROLE_CLASSES: Record<MessageBubbleRole, string> = {
  user: cn("bg-[var(--color-role-user)]/8 border-[var(--color-role-user)]/20"),
  assistant: cn("bg-[var(--color-brand-accent)]/6 border-[var(--color-brand-accent)]/20"),
  thinking: cn(
    "bg-[var(--color-role-thinking)]/8 border-[var(--color-role-thinking)]/20 italic text-text-secondary",
  ),
  tool: cn("bg-[var(--color-role-tool)]/8 border-[var(--color-role-tool)]/20"),
  status: cn("bg-[var(--color-hover-fill)] border-border-subtle text-text-secondary"),
  error: cn(
    "bg-[var(--color-role-error)]/10 border-[var(--color-role-error)]/35 text-text-primary",
  ),
  stderr: cn("bg-surface border-border-subtle font-mono text-xs text-text-muted"),
  raw: cn("bg-surface border-border-subtle font-mono text-xs text-text-muted"),
};

/**
 * Per-role header glyph color. The header label runs at footnote
 * (12-13px) semibold with .expanded width to match the macOS card
 * header.
 */
const ROLE_HEADER_TINT: Record<MessageBubbleRole, string> = {
  user: "text-[var(--color-role-user)]",
  assistant: "text-[var(--color-brand-accent)]",
  thinking: "text-[var(--color-role-thinking)]",
  tool: "text-[var(--color-role-tool)]",
  status: "text-text-muted",
  error: "text-[var(--color-role-error)]",
  stderr: "text-text-muted",
  raw: "text-text-muted",
};

/**
 * Single transcript message bubble — user / assistant / thinking / …
 * One per row. Hugged to the right for user / thinking, left for
 * everything else.
 *
 * The bubble is the only place markdown is rendered inline; tool
 * groups, status rows, retry cards, etc. have their own card surfaces
 * that decide whether to wrap their body in `MarkdownDocument` or a
 * plain `<pre>`.
 *
 * Width is controlled by the parent row (the transcript list assigns
 * a `replyCap` or `huggedUser` width). The bubble itself just sets
 * its alignment via `data-align`.
 */
export const MessageBubble = forwardRef<HTMLDivElement, MessageBubbleProps>(function MessageBubble(
  { role, headerLabel, text, attachments, trailing, className },
  ref,
) {
  const isHugged = role === "user" || role === "thinking";
  const align: "start" | "end" = isHugged ? "end" : "start";
  const label = headerLabel ?? ROLE_HEADER_LABEL[role];

  return (
    <div
      ref={ref}
      data-testid="message-bubble"
      data-role={role}
      data-align={align}
      className={cn(
        "rounded-xl border px-4 py-3 flex flex-col gap-2",
        ROLE_CLASSES[role],
        // Soften the body color in muted roles. We add this AFTER the
        // role class so it can override the role's text color.
        "text-[13px] leading-relaxed",
        className,
      )}
    >
      <div className="flex items-baseline justify-between gap-3">
        <span
          className={cn(
            "flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-wide",
            ROLE_HEADER_TINT[role],
          )}
        >
          {/* The pi mark on assistant messages (native assistant header logo). */}
          {role === "assistant" ? (
            <BrandIcon name="pi" size={11} className="translate-y-[1px]" />
          ) : null}
          {label}
        </span>
        {trailing ? <span className="shrink-0 text-[11px] text-text-muted">{trailing}</span> : null}
      </div>

      {attachments && attachments.length > 0 ? (
        <ul data-testid="message-bubble-attachments" className="flex flex-wrap gap-1.5">
          {attachments.map((attachment) => (
            <li
              key={attachment.id}
              data-kind={attachment.kind}
              className={cn(
                "inline-flex items-center gap-1 rounded-full border border-border-subtle bg-surface-elevated",
                "px-2 py-0.5 text-[11px] font-medium text-text-secondary",
              )}
            >
              {attachment.label}
            </li>
          ))}
        </ul>
      ) : null}

      {text ? (
        // For multi-line markdown bodies we delegate to MarkdownDocument
        // so fenced code + lists + headings all parse. Single-line
        // strings render fine through it too.
        <MarkdownDocument source={text} className="text-[13px]" />
      ) : null}
    </div>
  );
});

export default MessageBubble;
