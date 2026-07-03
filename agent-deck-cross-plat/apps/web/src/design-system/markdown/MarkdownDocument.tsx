/**
 * Block-level markdown renderer.
 *
 * Wraps `renderMarkdown` in a React component that:
 *   1. parses asynchronously (shiki + marked) so the bundle stays small
 *   2. holds onto previously-rendered HTML while re-parsing so the view
 *      doesn't flash blank on prop changes
 *   3. injects the sanitized HTML via `dangerouslySetInnerHTML`
 *      (the HTML is run through DOMPurify upstream, so this is safe)
 *
 * Styling uses semantic Tailwind tokens. The default `prose-like` class
 * map approximates the macOS `MarkdownTextView` look (headline weight,
 * muted blockquote bar, rounded code blocks). Consumers can override via
 * the `className` prop.
 */
import { forwardRef, useEffect, useState, type HTMLAttributes } from "react";
import { cn } from "../../lib/cn";
import { renderMarkdown, type ShikiThemeName } from "./markdown";

export interface MarkdownDocumentProps extends Omit<HTMLAttributes<HTMLDivElement>, "children"> {
  /** Markdown source text. */
  source: string;
  /** Shiki theme for fenced code blocks. */
  theme?: ShikiThemeName;
}

/** Tailwind utilities that style the rendered HTML tree. */
const BLOCK_STYLES = [
  // Layout / typography baseline
  "text-sm leading-relaxed text-text-primary",
  // Headings — match macOS `headlineSize / title3 + bold`
  "[&_h1]:mt-6 [&_h1]:mb-2 [&_h1]:text-xl [&_h1]:font-bold",
  "[&_h2]:mt-5 [&_h2]:mb-2 [&_h2]:text-lg [&_h2]:font-semibold",
  "[&_h3]:mt-4 [&_h3]:mb-2 [&_h3]:text-base [&_h3]:font-semibold",
  "[&_h4]:mt-3 [&_h4]:mb-1 [&_h4]:text-sm [&_h4]:font-semibold",
  "[&_h5]:mt-3 [&_h5]:mb-1 [&_h5]:text-sm [&_h5]:font-semibold",
  "[&_h6]:mt-3 [&_h6]:mb-1 [&_h6]:text-xs [&_h6]:font-semibold",
  // Paragraphs / breaks
  "[&_p]:mb-3 [&_p:last-child]:mb-0",
  // Lists
  "[&_ul]:my-2 [&_ul]:pl-6 [&_ul]:list-disc",
  "[&_ol]:my-2 [&_ol]:pl-6 [&_ol]:list-decimal",
  "[&_li]:my-1",
  // Inline marks
  "[&_strong]:font-semibold [&_em]:italic",
  "[&_del]:line-through [&_del]:opacity-70",
  // Inline code
  "[&_code]:rounded [&_code]:bg-surface-elevated [&_code]:px-1 [&_code]:py-[1px] [&_code]:font-mono [&_code]:text-[0.85em]",
  // Code blocks — shiki emits inline styles, so we only set chrome
  "[&_pre]:my-3 [&_pre]:overflow-x-auto [&_pre]:rounded-md [&_pre]:border [&_pre]:border-border-subtle [&_pre]:bg-surface-elevated [&_pre]:p-3",
  "[&_pre_code]:bg-transparent [&_pre_code]:p-0",
  // Blockquote bar
  "[&_blockquote]:my-3 [&_blockquote]:border-l-[3px] [&_blockquote]:border-border-strong [&_blockquote]:pl-3 [&_blockquote]:italic [&_blockquote]:text-text-secondary",
  // Tables
  "[&_table]:my-3 [&_table]:w-full [&_table]:border-collapse",
  "[&_th]:border-b [&_th]:border-border-strong [&_th]:px-2 [&_th]:py-1 [&_th]:text-left [&_th]:font-semibold",
  "[&_td]:border-b [&_td]:border-border-subtle [&_td]:px-2 [&_td]:py-1",
  // Links
  "[&_a]:text-accent [&_a]:underline [&_a:hover]:text-primary-hover",
  // Horizontal rule
  "[&_hr]:my-4 [&_hr]:border-0 [&_hr]:border-t [&_hr]:border-border-subtle",
];

export const MarkdownDocument = forwardRef<HTMLDivElement, MarkdownDocumentProps>(
  function MarkdownDocument({ source, theme, className, ...rest }, ref) {
    const [html, setHtml] = useState<string>("");

    useEffect(() => {
      let cancelled = false;
      renderMarkdown(source, { theme }).then((rendered) => {
        if (!cancelled) setHtml(rendered);
      });
      return () => {
        cancelled = true;
      };
    }, [source, theme]);

    return (
      <div ref={ref} data-md-document="" className={cn(BLOCK_STYLES, className)} {...rest}>
        <div data-md-document-content="" dangerouslySetInnerHTML={{ __html: html }} />
      </div>
    );
  },
);

export default MarkdownDocument;
