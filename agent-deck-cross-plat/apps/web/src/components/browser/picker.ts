/**
 * Click-to-select element picker for the desktop browser (Slice L3).
 *
 * The general browser (L2) hosts arbitrary sites in a REAL, HARDENED Chromium
 * guest — NO guest preload, contextIsolation:true, sandbox, nodeIntegration off
 * (apps/desktop/main.js `will-attach-webview`). L3 must NOT weaken any of that,
 * so the picker is injected purely via `webview.executeJavaScript(code, true)`:
 * Electron runs the string in the guest page and, because the string evaluates
 * to a Promise, RESOLVES the renderer's `await` with that Promise's value once
 * the user clicks (or Escape). No preload, no context-isolation change, no
 * bridge — just a self-contained script that installs a highlight overlay and a
 * one-shot capture-phase click listener, then tears itself down.
 *
 * `PICKER_CODE` is therefore a SELF-CONTAINED string (no external references —
 * it cannot import from this module since it runs in the guest realm). The pure
 * `buildElementSelector` / `normalizePickText` helpers below MIRROR the string's
 * selector + text logic so the algorithm is unit-testable in a Node vitest
 * environment without a real DOM; keep the two in sync when either changes.
 */

/** A validated pick: the clicked element's CSS selector, tag, and short text. */
export interface PickResult {
  readonly selector: string;
  readonly tagName: string;
  readonly text: string;
}

/** One node in an element's ancestor chain (target-first) for selector building.
 * `id` is a PRE-VETTED, unique, simple id (or null) — see `usableId` in the
 * injected code / the `SIMPLE_ID` rule below. */
export interface SelectorChainNode {
  readonly tagName: string;
  readonly id: string | null;
  /** 1-based index among same-tag element siblings (for `:nth-of-type`). */
  readonly nthOfType: number;
}

/** How deep the selector path climbs before giving up on an id anchor. */
const MAX_SELECTOR_DEPTH = 5;
/** Trimmed textContent cap carried onto the context for human context. */
const PICK_TEXT_MAX = 80;

/**
 * A "simple" id safe to embed verbatim as `#id` (no CSS escaping needed) — an
 * ASCII letter followed by word chars / hyphens. Non-simple ids fall back to
 * the `:nth-of-type` path. Kept identical to the injected code's `isSimpleId`.
 */
export const SIMPLE_ID = /^[A-Za-z][\w-]*$/;

/**
 * Build a CSS selector from a target-first ancestor chain, mirroring the
 * injected picker's `selectorFor`:
 *   - anchor on the first node (climbing from the target) that carries a usable
 *     id → `#id` and stop;
 *   - otherwise emit `tag:nth-of-type(n)` per level (or a bare `html`/`body`
 *     terminal), capped at MAX_SELECTOR_DEPTH levels;
 *   - join deepest→shallowest with " > " (so the string reads ancestor→target).
 */
export function buildElementSelector(chain: readonly SelectorChainNode[]): string {
  if (chain.length === 0) return "";
  const parts: string[] = [];
  for (let i = 0; i < chain.length && i < MAX_SELECTOR_DEPTH; i += 1) {
    const node = chain[i]!;
    if (node.id) {
      parts.push(`#${node.id}`);
      break;
    }
    const tag = node.tagName.toLowerCase();
    if (tag === "html" || tag === "body") {
      parts.push(tag);
      break;
    }
    parts.push(`${tag}:nth-of-type(${node.nthOfType})`);
  }
  return parts.reverse().join(" > ");
}

/** Collapse whitespace, trim, and cap a picked element's text (donor-style). */
export function normalizePickText(raw: string, max: number = PICK_TEXT_MAX): string {
  return raw.replace(/\s+/g, " ").trim().slice(0, max);
}

/**
 * The picker runs in the guest's MAIN world, which shares prototypes with the
 * UNTRUSTED page — a hostile page can poison e.g. `Element.prototype.tagName`'s
 * getter so the returned strings carry newlines + a forged `</element_context>`
 * that would break out of the prompt block and inject instructions to pi. So the
 * renderer treats every returned string as fully untrusted: strip control chars
 * (incl. newlines) AND `<` (can't forge a close tag), then clamp the length —
 * BEFORE the value crosses into the app / the prompt. Never rely on the
 * guest-side normalization being honest.
 */
const MAX_SELECTOR_CHARS = 2000;
const MAX_TAGNAME_CHARS = 50;
const MAX_TEXT_CHARS = 1000;

function sanitizeGuestString(value: unknown, max: number): string {
  if (typeof value !== "string") return "";
  let out = "";
  for (const ch of value) {
    const code = ch.codePointAt(0) ?? 0;
    // Drop control chars (incl. newlines/CR/tab) and '<' (so the guest cannot
    // forge a </element_context> close tag or newline-break the prompt block).
    if (code < 0x20 || (code >= 0x7f && code <= 0x9f) || ch === "<") continue;
    out += ch;
    if (out.length >= max) break;
  }
  return out.trim();
}

/**
 * Validate the structured-clone value `executeJavaScript` resolves with into a
 * `PickResult`, or null (Escape / cancel / a non-element click / anything
 * malformed). Every guest string is sanitized (see above) — the renderer never
 * trusts the guest realm's return shape OR its contents.
 */
export function parsePickResult(value: unknown): PickResult | null {
  if (value === null || typeof value !== "object") return null;
  const candidate = value as Record<string, unknown>;
  const selector = sanitizeGuestString(candidate.selector, MAX_SELECTOR_CHARS);
  const tagName = sanitizeGuestString(candidate.tagName, MAX_TAGNAME_CHARS);
  if (selector.length === 0 || tagName.length === 0) return null;
  return { selector, tagName, text: sanitizeGuestString(candidate.text, MAX_TEXT_CHARS) };
}

/**
 * The self-contained picker script injected into the guest. Evaluates to a
 * Promise that resolves with `{ selector, tagName, text }` on the next click
 * (capture phase; the click is swallowed so it never activates the page) or
 * `null` on Escape / external teardown. ALWAYS removes its overlay + listeners
 * before resolving. Re-injecting cancels any prior picker first.
 *
 * SECURITY: runs in the sandboxed, context-isolated guest realm with no preload
 * — it touches only the guest's own DOM and returns a plain, string-only object.
 */
export const PICKER_CODE = `(() => {
  const OVERLAY_ID = "__agentdeck_pick_overlay__";
  const prior = document.getElementById(OVERLAY_ID);
  if (prior && typeof prior.__agentdeckTeardown === "function") { prior.__agentdeckTeardown(); }

  const overlay = document.createElement("div");
  overlay.id = OVERLAY_ID;
  overlay.setAttribute("aria-hidden", "true");
  overlay.style.cssText = [
    "position:fixed", "top:0", "left:0", "width:0", "height:0",
    "pointer-events:none", "z-index:2147483647", "box-sizing:border-box",
    "outline:2px solid #4c8bf5", "outline-offset:0",
    "background:rgba(76,139,245,0.15)", "transition:none", "display:none"
  ].join(";");
  (document.body || document.documentElement).appendChild(overlay);

  const isSimpleId = (id) => typeof id === "string" && /^[A-Za-z][\\w-]*$/.test(id);
  const usableId = (el) => {
    const id = el.id;
    if (!isSimpleId(id)) return null;
    try { if (document.querySelectorAll("#" + id).length !== 1) return null; } catch (_e) { return null; }
    return id;
  };
  const nthOfType = (el) => {
    let n = 1; let sib = el.previousElementSibling;
    while (sib) { if (sib.tagName === el.tagName) n += 1; sib = sib.previousElementSibling; }
    return n;
  };
  const selectorFor = (start) => {
    if (!start || start.nodeType !== 1) return "";
    const parts = [];
    let el = start; let depth = 0;
    while (el && el.nodeType === 1 && depth < 5) {
      const id = usableId(el);
      if (id) { parts.push("#" + id); break; }
      const tag = el.tagName.toLowerCase();
      if (tag === "html" || tag === "body") { parts.push(tag); break; }
      parts.push(tag + ":nth-of-type(" + nthOfType(el) + ")");
      el = el.parentElement; depth += 1;
    }
    return parts.reverse().join(" > ");
  };

  return new Promise((resolve) => {
    let done = false;
    const onMove = (e) => {
      const t = e.target;
      if (!t || t === overlay || t.nodeType !== 1) { overlay.style.display = "none"; return; }
      const r = t.getBoundingClientRect();
      overlay.style.display = "block";
      overlay.style.top = r.top + "px";
      overlay.style.left = r.left + "px";
      overlay.style.width = r.width + "px";
      overlay.style.height = r.height + "px";
    };
    function teardown() {
      document.removeEventListener("mousemove", onMove, true);
      document.removeEventListener("click", onClick, true);
      document.removeEventListener("keydown", onKey, true);
      if (overlay && overlay.parentNode) overlay.parentNode.removeChild(overlay);
    }
    const finish = (value) => {
      if (done) return; done = true;
      teardown();
      resolve(value);
    };
    function onClick(e) {
      const t = e.target;
      e.preventDefault(); e.stopPropagation();
      if (typeof e.stopImmediatePropagation === "function") e.stopImmediatePropagation();
      if (!t || t === overlay || t.nodeType !== 1) { finish(null); return; }
      const text = (t.textContent || "").replace(/\\s+/g, " ").trim().slice(0, 80);
      finish({ selector: selectorFor(t), tagName: t.tagName.toLowerCase(), text: text });
    }
    function onKey(e) { if (e.key === "Escape") { e.preventDefault(); finish(null); } }
    overlay.__agentdeckTeardown = () => finish(null);
    document.addEventListener("mousemove", onMove, true);
    document.addEventListener("click", onClick, true);
    document.addEventListener("keydown", onKey, true);
  });
})();`;

/**
 * A tiny teardown script: cancel an in-flight picker in the guest (resolving its
 * Promise with null) without needing a click. Injected when pick mode is
 * cancelled from the renderer (toggle off, page-tab switch, unmount).
 */
export const PICKER_TEARDOWN_CODE = `(() => {
  const el = document.getElementById("__agentdeck_pick_overlay__");
  if (el && typeof el.__agentdeckTeardown === "function") el.__agentdeckTeardown();
  return null;
})();`;
