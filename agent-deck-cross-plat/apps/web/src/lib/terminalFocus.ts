/**
 * Terminal focus detection, ported near-verbatim from t3code's
 * `apps/web/src/lib/terminalFocus.ts` (MIT). The drawer stamps
 * `data-terminal-owner` on its root; global keyboard shortcuts consult this so
 * shell-bound keystrokes (Ctrl+C, Ctrl+N, …) are never hijacked while the
 * terminal owns focus. We have a single owner surface (the drawer), so the
 * donor's owner union collapses to a boolean.
 */
export function isTerminalFocused(): boolean {
  const activeElement = document.activeElement;
  if (!(activeElement instanceof HTMLElement)) return false;
  if (!activeElement.isConnected) return false;
  return activeElement.closest("[data-terminal-owner]") !== null;
}
