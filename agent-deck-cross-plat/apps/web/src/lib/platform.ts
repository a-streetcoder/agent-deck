/**
 * Platform string for keybinding resolution (Slice 19 a11y batch).
 *
 * The keybindings core (`@agent-deck/contracts` keybindings.ts) takes a raw
 * platform STRING and classifies it with `/mac|iphone|ipad|ipod/i` — it only
 * needs "is this an Apple platform" to pick ⌘ vs Ctrl. `navigator.platform` is
 * deprecated; prefer the modern high-entropy `navigator.userAgentData.platform`
 * (returns "macOS" / "Windows" / "Linux"), which the same regex classifies
 * correctly ("macOS" matches `/mac/i`). Fall back to the legacy field, then to
 * an empty string (→ treated as non-Mac, i.e. Ctrl — the correct default for
 * our Linux/Windows targets when nothing is detectable).
 *
 * Centralized here so the three call sites (command palette, keybindings editor,
 * global shortcut dispatch) share ONE detection path — they were each reading
 * the deprecated `navigator.platform` inline.
 */
export function detectPlatform(): string {
  const uaData = (navigator as Navigator & { userAgentData?: { platform?: string } }).userAgentData;
  const modern = uaData?.platform;
  // Coalesce an empty-but-present modern value to the legacy field too (not just
  // null/undefined), so a browser reporting "" doesn't shadow a usable
  // navigator.platform. Then default to "" (→ classified non-Mac, i.e. Ctrl).
  if (modern && modern.length > 0) return modern;
  return navigator.platform ?? "";
}
