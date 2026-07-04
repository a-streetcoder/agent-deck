/**
 * Cross-platform markdown renderer.
 *
 * Mirrors the macOS `MarkedJSSource.swift` / `MarkdownViews.swift` pipeline:
 *
 *   marked (gfm: true, breaks: true, headerIds: off, mangle: off)
 *     -> shiki for fenced code blocks (lazy-loaded; cached highlighter)
 *     -> DOMPurify with a conservative allowlist
 *     -> postprocess: add target=_blank rel=noopener noreferrer to http(s)
 *
 * `renderMarkdown` returns a Promise<string> of sanitized HTML; consumers
 * inject it via `dangerouslySetInnerHTML`. The string is safe — DOMPurify
 * strips scripts, event handlers, iframes, and javascript: URLs.
 *
 * Two modes:
 *   - block (default): full document, block elements wrapped (<p>, <h1>, etc.)
 *   - inline: only inline marks (<strong>, <em>, <code>, <a>, etc.)
 */
import { marked, Marked } from "marked";
import DOMPurify from "dompurify";

/** Shiki theme name. Kept loose so callers can pass any bundled theme. */
export type ShikiThemeName = string;

export interface RenderMarkdownOptions {
  /** If true, parse only inline-level tokens (no <p>, <h1>, lists, etc.). */
  inline?: boolean;
  /** Shiki theme name for fenced code highlighting. Defaults to `github-dark`. */
  theme?: ShikiThemeName;
}

// ---------------------------------------------------------------------------
// Shiki highlighter (lazy, cached)
// ---------------------------------------------------------------------------

type HighlighterInstance = {
  codeToHtml: (code: string, opts: { lang: string; theme: string }) => string;
  getLoadedLanguages: () => string[];
  loadLanguage: (lang: string) => Promise<void>;
};

let highlighterPromise: Promise<HighlighterInstance> | null = null;
const DEFAULT_THEME: ShikiThemeName = "github-dark";

// A small starter set of languages — enough to cover most fenced blocks
// without paying the cost of every grammar. Additional langs are loaded
// on demand via `loadLanguage`.
const PRELOADED_LANGUAGES = [
  "javascript",
  "typescript",
  "tsx",
  "jsx",
  "json",
  "bash",
  "shell",
  "python",
  "rust",
  "swift",
  "html",
  "css",
  "markdown",
  "yaml",
  "sql",
] as const;

async function getHighlighter(theme: ShikiThemeName): Promise<HighlighterInstance> {
  if (highlighterPromise) return highlighterPromise;
  highlighterPromise = (async () => {
    // Dynamic import keeps shiki out of the initial bundle.
    const shiki = await import("shiki");
    const instance = await shiki.createHighlighter({
      themes: [theme],
      langs: [...PRELOADED_LANGUAGES],
    });
    return instance as unknown as HighlighterInstance;
  })();
  return highlighterPromise;
}

/** Normalise common language aliases that marked passes through verbatim. */
function normalizeLang(lang: string): string {
  const l = lang.trim().toLowerCase();
  if (!l) return "text";
  if (l === "js") return "javascript";
  if (l === "ts") return "typescript";
  if (l === "py") return "python";
  if (l === "sh" || l === "zsh") return "bash";
  if (l === "yml") return "yaml";
  return l;
}

/** Render a fenced code block with shiki, falling back to escaped plain text. */
async function highlightCode(code: string, lang: string, theme: ShikiThemeName): Promise<string> {
  const normalized = normalizeLang(lang);
  try {
    const hl = await getHighlighter(theme);
    const loaded = new Set(hl.getLoadedLanguages());
    if (!loaded.has(normalized) && normalized !== "text") {
      try {
        await hl.loadLanguage(normalized);
      } catch {
        // Unknown grammar — fall through to plain rendering.
        return `<pre><code>${escapeHtml(code)}</code></pre>`;
      }
    }
    return hl.codeToHtml(code, { lang: normalized, theme });
  } catch {
    return `<pre><code>${escapeHtml(code)}</code></pre>`;
  }
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

// ---------------------------------------------------------------------------
// marked setup
// ---------------------------------------------------------------------------

/**
 * Walk all fenced code blocks and replace their `text` with pre-highlighted
 * HTML inside a sentinel <span>. The custom renderer below then unwraps it.
 *
 * Why a sentinel? `marked.use({ async: true })` lets us run async work, but
 * the renderer API expects synchronous output. We pre-resolve highlighting
 * into the token tree via `walkTokens`, then emit raw HTML in the renderer.
 */
function buildMarkedInstance(theme: ShikiThemeName): Marked {
  const instance = new Marked({
    gfm: true,
    breaks: true,
    async: true,
  });

  instance.use({
    async walkTokens(token) {
      if (token.type === "code") {
        const code = (token as { text: string }).text ?? "";
        const lang = (token as { lang?: string }).lang ?? "";
        const highlighted = await highlightCode(code, lang, theme);
        (token as unknown as { _highlighted?: string })._highlighted = highlighted;
      }
    },
    renderer: {
      code(token) {
        const cached = (token as unknown as { _highlighted?: string })._highlighted;
        if (cached) return cached;
        const text = (token as { text: string }).text ?? "";
        return `<pre><code>${escapeHtml(text)}</code></pre>`;
      },
    },
  });

  return instance;
}

// ---------------------------------------------------------------------------
// DOMPurify config
// ---------------------------------------------------------------------------

/** Conservative allowlist — block tags, inline marks, table chrome. */
const PURIFY_ALLOWED_TAGS = [
  // block
  "p",
  "div",
  "span",
  "br",
  "hr",
  "h1",
  "h2",
  "h3",
  "h4",
  "h5",
  "h6",
  "blockquote",
  "pre",
  "code",
  // lists
  "ul",
  "ol",
  "li",
  // inline marks
  "strong",
  "em",
  "del",
  "s",
  "sub",
  "sup",
  "mark",
  "a",
  "img",
  // tables
  "table",
  "thead",
  "tbody",
  "tfoot",
  "tr",
  "th",
  "td",
  // misc
  "input", // for task-list checkboxes (DOMPurify will strip dangerous attrs)
];

const PURIFY_ALLOWED_ATTR = [
  "href",
  "title",
  "alt",
  "src",
  "class",
  "style", // shiki relies on inline style for token colours
  "colspan",
  "rowspan",
  "align",
  // task list
  "type",
  "checked",
  "disabled",
];

/**
 * `style` is only needed for shiki's inline token colours. Restrict it to a
 * narrow property allowlist so raw markdown HTML can't smuggle arbitrary CSS
 * (overlay/redress tricks) through sanitization.
 */
const STYLE_PROPERTY_ALLOWLIST = new Set([
  "color",
  "background-color",
  "font-style",
  "font-weight",
  "text-decoration",
]);

let purifyHooksInstalled = false;
function installPurifyHooks(): void {
  if (purifyHooksInstalled) return;
  purifyHooksInstalled = true;
  DOMPurify.addHook("afterSanitizeAttributes", (node) => {
    if (!(node instanceof Element) || !node.hasAttribute("style")) return;
    const style = (node as HTMLElement).style;
    for (let i = style.length - 1; i >= 0; i -= 1) {
      const property = style.item(i);
      if (!STYLE_PROPERTY_ALLOWLIST.has(property)) style.removeProperty(property);
    }
    if (style.length === 0) node.removeAttribute("style");
  });
}

function sanitize(html: string): string {
  installPurifyHooks();
  return DOMPurify.sanitize(html, {
    ALLOWED_TAGS: PURIFY_ALLOWED_TAGS,
    ALLOWED_ATTR: PURIFY_ALLOWED_ATTR,
    // Block javascript: / data: URLs in href but allow safe schemes.
    ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto|tel|ftp):|[^a-z]|[a-z+.-]+(?:[^a-z+.\-:]|$))/i,
    ALLOW_DATA_ATTR: false,
    FORBID_TAGS: ["script", "iframe", "style", "object", "embed", "form"],
  }) as string;
}

// ---------------------------------------------------------------------------
// Post-processing
// ---------------------------------------------------------------------------

/**
 * Walk the sanitized HTML and add `target="_blank" rel="noopener noreferrer"`
 * to any anchor whose href is an absolute http(s) URL. Fragment, relative,
 * and mailto links are left alone so they navigate in-window.
 */
function annotateExternalLinks(html: string): string {
  // Use a DOMParser when available (jsdom + browser), otherwise return as-is.
  if (typeof DOMParser === "undefined") return html;
  const doc = new DOMParser().parseFromString(`<div>${html}</div>`, "text/html");
  const anchors = doc.querySelectorAll("a[href]");
  anchors.forEach((a) => {
    const href = a.getAttribute("href") ?? "";
    if (/^https?:\/\//i.test(href)) {
      a.setAttribute("target", "_blank");
      a.setAttribute("rel", "noopener noreferrer");
    }
  });
  // body contains the wrapped <div>; return its inner HTML.
  const wrapper = doc.body.firstElementChild;
  return wrapper ? wrapper.innerHTML : html;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Render a markdown string to sanitized HTML.
 *
 * Block mode (default) yields full block layout: <p>, <h1>..<h6>, <ul>,
 * <table>, fenced code blocks highlighted via shiki, etc.
 *
 * Inline mode strips block wrappers and only emits inline marks
 * (<strong>, <em>, <code>, <a>, <br>, etc.). Use for compact contexts
 * like row subtitles where a paragraph wrapper would add unwanted spacing.
 */
export async function renderMarkdown(
  source: string,
  opts: RenderMarkdownOptions = {},
): Promise<string> {
  const theme = opts.theme ?? DEFAULT_THEME;

  let raw: string;
  if (opts.inline) {
    // Inline mode bypasses our custom shiki renderer (no code blocks at the
    // top level anyway) and uses the default marked instance.
    raw = await marked.parseInline(source, { gfm: true, breaks: true, async: true });
  } else {
    const instance = buildMarkedInstance(theme);
    raw = await instance.parse(source);
  }

  const clean = sanitize(raw);
  return annotateExternalLinks(clean);
}
