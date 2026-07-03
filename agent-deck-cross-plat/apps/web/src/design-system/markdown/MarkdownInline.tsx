/**
 * Inline-only markdown renderer.
 *
 * Use for compact contexts: transcript row subtitles, tooltip bodies,
 * label captions — anywhere a paragraph wrapper would inject unwanted
 * vertical spacing. Output is a single inline-level element (`<span>` by
 * default) containing only inline marks: <strong>, <em>, <code>, <a>,
 * <del>, <br>, etc.
 */
import { forwardRef, useEffect, useState, type HTMLAttributes } from "react";
import { cn } from "../../lib/cn";
import { renderMarkdown } from "./markdown";

export interface MarkdownInlineProps extends Omit<HTMLAttributes<HTMLSpanElement>, "children"> {
  /** Markdown source — only inline-level tokens are parsed. */
  source: string;
}

const INLINE_STYLES = [
  "text-text-primary",
  "[&_strong]:font-semibold [&_em]:italic",
  "[&_del]:line-through [&_del]:opacity-70",
  "[&_code]:rounded [&_code]:bg-surface-elevated [&_code]:px-1 [&_code]:py-[1px] [&_code]:font-mono [&_code]:text-[0.85em]",
  "[&_a]:text-accent [&_a]:underline [&_a:hover]:text-primary-hover",
];

export const MarkdownInline = forwardRef<HTMLSpanElement, MarkdownInlineProps>(
  function MarkdownInline({ source, className, ...rest }, ref) {
    const [html, setHtml] = useState<string>("");

    useEffect(() => {
      let cancelled = false;
      renderMarkdown(source, { inline: true }).then((rendered) => {
        if (!cancelled) setHtml(rendered);
      });
      return () => {
        cancelled = true;
      };
    }, [source]);

    return (
      <span
        ref={ref}
        data-md-inline=""
        className={cn(INLINE_STYLES, className)}
        dangerouslySetInnerHTML={{ __html: html }}
        {...rest}
      />
    );
  },
);

export default MarkdownInline;
