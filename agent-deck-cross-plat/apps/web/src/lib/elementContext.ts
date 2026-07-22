/**
 * Preview element contexts (Slice 16), pattern-ported from t3code's
 * `apps/web/src/lib/elementContext.ts` (MIT). A pending element context anchors
 * to one element the user points out in the S15 preview and serializes into the
 * outgoing prompt as the donor's `<element_context>` block: a `- <tag>:` header
 * per element followed by indented `url:` / `selector:` / `note:` metadata
 * lines, appended after the trimmed prompt.
 *
 * ── Mechanism note (why this is the manual-capture subset) ──────────────────
 * The donor captures element context by running an in-frame agent INSIDE the
 * previewed page: an Electron `<webview preload>` (`apps/desktop/.../PickPreload`)
 * that reads the guest DOM via `react-grab/primitives` and reports the pick over
 * `ipcRenderer` IPC (`PreviewAutomationHosts.tsx`, gated on `isElectron &&
 * previewBridge?.automation`). That mechanism is impossible with OUR preview
 * surface: S15 embeds the dev server in a plain sandboxed cross-origin
 * `<iframe>` (deliberately — it works identically in a browser and the Electron
 * renderer, and the desktop bridge exposes no webview/BrowserView). The parent
 * frame cannot read a cross-origin iframe's DOM, cannot inject a script into a
 * sandboxed frame, and an arbitrary dev-server page has no postMessage listener
 * we could talk to — so there is no way to run the donor's inspector in-frame.
 *
 * Following the task's documented fallback, we implement the SUBSET that works
 * cross-platform: a manual "add element context" — the user supplies a CSS
 * selector and/or a free-text description of the element, the current preview
 * URL is captured automatically, and the result becomes the SAME card shape that
 * serializes into the SAME `<element_context>` block pi expects. The donor's
 * DOM-derived fields (html preview, author styles, source stack frame, React
 * component name) are unavailable without the in-frame agent and are simply
 * omitted; the user's `note` — which the donor would infer from the DOM — is
 * carried as an extra indented `note:` line (composes cleanly with the donor's
 * generic `key: value` block parser). A screenshot of the visible frame is NOT
 * captured: html2canvas cannot rasterize cross-origin iframe content, there is
 * no user-gesture-free frame-capture API, and the donor's crop came from the
 * Electron overlay compositing the guest — none of which we have.
 *
 * The whole feature is CLIENT-side, matching the donor (and our own S12 review
 * comments): serialization into the prompt happens in the web app at send time,
 * and the pending set is composer state — here in the zustand store keyed by
 * session id, so sets stay separate across session switches and die with the
 * page. This mirrors S12 `reviewComments.ts` deliberately rather than sharing a
 * generic abstraction: the two pending-context families are intentionally
 * symmetric (session-keyed record, serialize-append-and-clear on send) but carry
 * different payloads and lifecycles, exactly as the donor keeps `elementContext`
 * / `reviewCommentContext` / `terminalContext` as independent parallel modules.
 */

import { sanitizeLoopbackUrl } from "./loopback.ts";

/** A pending "preview element" context for the CURRENT session's composer. */
export interface PendingElementContext {
  /** Stable composer-side id for keyed rendering + dedupe + removal. */
  readonly id: string;
  /** Preview page URL where the element lives (captured automatically). */
  readonly pageUrl: string;
  /** User-supplied CSS selector, or null when only a description was given. */
  readonly selector: string | null;
  /** Lowercase tag derived from the selector, else "element". */
  readonly tagName: string;
  /** The user's free-text description of the element / desired change. */
  readonly note: string;
}

/** Field clamps (donor's ELEMENT_CONTEXT_* limits, trimmed to our lean shape). */
const NOTE_LIMIT = 4000;
const SELECTOR_LIMIT = 1000;
const TAG_LABEL_MAX = 24;

function truncate(value: string, limit: number): string {
  if (value.length <= limit) return value;
  return `${value.slice(0, Math.max(0, limit - 1))}…`;
}

/**
 * Derive a lowercase tag name from a CSS selector: the type selector of its
 * LAST compound (`div > button.primary` → `button`), else `"element"` when the
 * selector targets by class/id/attribute only (`.cta`, `#save`) or is absent.
 * The last compound is the actual target of a descendant selector, so it is the
 * highest-signal tag for the chip label.
 */
export function deriveTagName(selector: string | null): string {
  if (selector === null) return "element";
  const trimmed = selector.trim();
  if (trimmed.length === 0) return "element";
  // Split on descendant/child/sibling combinators; take the final compound.
  const compounds = trimmed.split(/\s*[>+~]\s*|\s+/).filter((part) => part.length > 0);
  const last = compounds[compounds.length - 1] ?? trimmed;
  // A leading type selector is an identifier before any .#[:( qualifier.
  const match = /^([a-zA-Z][a-zA-Z0-9-]*)/.exec(last);
  return match ? match[1]!.toLowerCase() : "element";
}

function shortenTag(tagName: string): string {
  if (tagName.length <= TAG_LABEL_MAX) return tagName;
  return `${tagName.slice(0, TAG_LABEL_MAX - 1)}…`;
}

/** Compact chip/header label — `<button>` (donor `formatElementContextLabel`,
 * component-name branch dropped: we have no in-frame agent to compute it). */
export function formatElementContextLabel(context: Pick<PendingElementContext, "tagName">): string {
  return `<${shortenTag(context.tagName)}>`;
}

/**
 * Build a pending element context from a manual capture. Returns null when the
 * user gave neither a selector nor a note (nothing to anchor to) — the URL alone
 * is not a usable context.
 */
export function buildPendingElementContext(input: {
  id: string;
  pageUrl: string;
  selector: string | null;
  note: string;
  /**
   * The URL sanitizer. Defaults to {@link sanitizeLoopbackUrl} (the loopback
   * preview, where the URL is derived from untrusted dev-script stdout). The
   * general desktop browser passes {@link sanitizeHttpUrl} so a real non-loopback
   * page URL isn't silently dropped (still injection-safe — see loopback.ts).
   */
  sanitizeUrl?: (raw: string) => string;
  /** Explicit tag (the browser picker knows the real tag); falls back to
   * deriving it from the selector when omitted (the manual-capture path). */
  tagName?: string;
}): PendingElementContext | null {
  const selector = input.selector?.trim() || null;
  const note = input.note.trim();
  // The pageUrl is the ONE field with non-user provenance — sanitized to a
  // normalized URL (or "", which omits the `url:` line) so a hostile URL can
  // neither inject newlines that break the block nor (for the loopback default)
  // smuggle a non-loopback origin.
  const pageUrl = (input.sanitizeUrl ?? sanitizeLoopbackUrl)(input.pageUrl);
  if (selector === null && note.length === 0) return null;
  return {
    id: input.id,
    pageUrl,
    selector: selector === null ? null : truncate(selector, SELECTOR_LIMIT),
    tagName: input.tagName?.trim() ? input.tagName.trim().toLowerCase() : deriveTagName(selector),
    note: truncate(note, NOTE_LIMIT),
  };
}

let nextElementContextSequence = 0;

/** Monotonic composer-side id for a captured element context (donor
 * `newElementContextId`). */
export function newElementContextId(): string {
  nextElementContextSequence += 1;
  return `el_${nextElementContextSequence.toString(36)}`;
}

/** Nest a multi-line value one level under an indented `key:` heading (heading
 * at 2 spaces, content at 4), so a multi-line note reads as clearly owned by it. */
function indentLines(value: string): string[] {
  return value.split("\n").map((line) => `    ${line}`);
}

/** The donor's `buildSingleContextLines`, over the fields our capture carries. */
function buildSingleContextLines(context: PendingElementContext): string[] {
  const lines: string[] = [];
  lines.push(`- ${formatElementContextLabel(context)}:`);
  if (context.pageUrl.length > 0) lines.push(`  url: ${context.pageUrl}`);
  if (context.selector) lines.push(`  selector: ${context.selector}`);
  const note = context.note.trim();
  if (note.length > 0) {
    if (note.includes("\n")) {
      lines.push("  note:");
      lines.push(...indentLines(note));
    } else {
      lines.push(`  note: ${note}`);
    }
  }
  return lines;
}

/**
 * Serialize element contexts into the `<element_context>` block appended to the
 * outgoing message (donor `buildElementContextBlock`): one `- <tag>:` entry per
 * context, entries separated by a blank line.
 */
export function buildElementContextBlock(contexts: ReadonlyArray<PendingElementContext>): string {
  if (contexts.length === 0) return "";
  const lines: string[] = [];
  for (let index = 0; index < contexts.length; index += 1) {
    lines.push(...buildSingleContextLines(contexts[index]!));
    if (index < contexts.length - 1) lines.push("");
  }
  return ["<element_context>", ...lines, "</element_context>"].join("\n");
}

/**
 * Donor `appendElementContextsToPrompt`: the block is appended after the trimmed
 * prompt (blank-line separated), or stands alone when the composer text is empty
 * (a contexts-only turn).
 */
export function appendElementContextsToPrompt(
  prompt: string,
  contexts: ReadonlyArray<PendingElementContext>,
): string {
  const block = buildElementContextBlock(contexts);
  if (block.length === 0) return prompt;
  const trimmed = prompt.trim();
  return trimmed.length > 0 ? `${trimmed}\n\n${block}` : block;
}
