import { useEffect, useMemo, useState } from "react";
import {
  chordFromEvent,
  DEFAULT_KEYBINDINGS,
  findChordConflicts,
  formatChordString,
  isValidChord,
  resolveKeybindings,
  type KeybindingBinding,
  type KeybindingCommand,
} from "@agent-deck/contracts";
import { RotateCcw, X } from "lucide-react";
import { cn } from "@/lib/cn";
import { detectPlatform } from "@/lib/platform";
import { COMMAND_DEFINITIONS, commandLabel } from "../state/commands.ts";
import { useAppStore } from "../state/store.ts";

/**
 * The keybindings editor (Slice 14): a sheet listing every rebindable command
 * with its live chord. Recording captures the next keypress into a chord
 * ({@link chordFromEvent}), warns when it collides with an existing binding
 * (the donor's KeybindingsUpdateToast "already bound" pattern, surfaced as a
 * toast), and applies it live — the store update re-resolves the map that the
 * global handler and palette read, and a PATCH /settings persists it. Rebinding
 * to the default drops the override so the row reads "Default" again.
 */

const DEFAULT_CHORD_BY_COMMAND = new Map<KeybindingCommand, string>(
  DEFAULT_KEYBINDINGS.map((binding) => [binding.command, binding.key]),
);

async function persistKeybindings(keybindings: readonly KeybindingBinding[]): Promise<void> {
  try {
    await fetch("/settings", {
      method: "PATCH",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ keybindings }),
    });
  } catch {
    // Best-effort: the live in-memory rebind already applied; a failed persist
    // just means it won't survive a reload.
  }
}

export function KeybindingsEditor() {
  const open = useAppStore((state) => state.keybindingsEditorOpen);
  const setOpen = useAppStore((state) => state.setKeybindingsEditorOpen);
  const keybindings = useAppStore((state) => state.keybindings);
  const setKeybindings = useAppStore((state) => state.setKeybindings);
  const pushToast = useAppStore((state) => state.pushToast);

  const [capturing, setCapturing] = useState<KeybindingCommand | null>(null);
  const platform = detectPlatform();

  useEffect(() => {
    if (!open) setCapturing(null);
  }, [open]);

  const resolved = useMemo(() => resolveKeybindings(keybindings), [keybindings]);

  const rows = useMemo(
    () =>
      [...COMMAND_DEFINITIONS].sort(
        (left, right) =>
          left.group.localeCompare(right.group) || left.label.localeCompare(right.label),
      ),
    [],
  );

  const applyOverride = (command: KeybindingCommand, key: string): void => {
    const isDefault = DEFAULT_CHORD_BY_COMMAND.get(command) === key;
    // Replace any prior override for this command; drop it entirely when the new
    // chord equals the shipped default so the row shows as Default.
    const next = keybindings.filter((binding) => binding.command !== command);
    if (!isDefault) next.push({ command, key });

    const conflicts = findChordConflicts(resolved, command, key, platform);
    setKeybindings(next);
    void persistKeybindings(next);

    if (conflicts.length > 0) {
      const names = [...new Set(conflicts.map(commandLabel))].join(", ");
      pushToast({
        kind: "error",
        message: `${formatChordString(key, platform)} is also bound to ${names}`,
      });
    }
  };

  // While open: capture the next real chord for a recording row, and (when
  // idle) close on Escape — parity with the command palette, and reachable
  // even though the global shortcut handler is inert while the editor is open.
  useEffect(() => {
    if (!open) return;
    const onKeyDown = (event: KeyboardEvent): void => {
      if (capturing === null) {
        // Idle: Escape closes; every other key passes through untouched.
        if (event.key === "Escape") {
          event.preventDefault();
          setOpen(false);
        }
        return;
      }
      event.preventDefault();
      event.stopPropagation();
      if (event.key === "Escape") {
        setCapturing(null);
        return;
      }
      const chord = chordFromEvent(event, platform);
      if (chord === null) return; // modifier-only so far — keep waiting
      if (!isValidChord(chord)) {
        pushToast({ kind: "error", message: "Add a modifier (Ctrl/⌘/Alt) to bind a shortcut" });
        setCapturing(null);
        return;
      }
      applyOverride(capturing, chord);
      setCapturing(null);
    };
    window.addEventListener("keydown", onKeyDown, true);
    return () => window.removeEventListener("keydown", onKeyDown, true);
  }, [open, capturing, platform]);

  const resetOverride = (command: KeybindingCommand): void => {
    const next = keybindings.filter((binding) => binding.command !== command);
    setKeybindings(next);
    void persistKeybindings(next);
  };

  if (!open) return null;

  const isOverridden = (command: KeybindingCommand): boolean =>
    keybindings.some((binding) => binding.command === command);

  return (
    <div
      className="fixed inset-0 z-50 flex items-start justify-center bg-black/40 p-4 pt-[10vh] backdrop-blur-sm"
      data-testid="keybindings-editor"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) setOpen(false);
      }}
    >
      <div
        className="flex max-h-[80vh] w-full max-w-[560px] flex-col overflow-hidden rounded-xl border border-border-strong bg-surface-elevated shadow-card"
        role="dialog"
        aria-modal="true"
        aria-label="Keybindings"
        data-testid="keybindings-editor-dialog"
      >
        <div className="flex items-center justify-between border-b border-border-subtle px-4 py-3">
          <div>
            <h2
              className="text-sm font-semibold text-text-primary"
              style={{ fontStretch: "expanded" }}
            >
              Keybindings
            </h2>
            <p className="text-xs text-text-muted">Click a shortcut, then press the new keys.</p>
          </div>
          <button
            type="button"
            className="rounded-md p-1.5 text-text-muted transition-colors hover:bg-[var(--color-hover-fill)]"
            aria-label="Close keybindings"
            data-testid="keybindings-editor-close"
            onClick={() => setOpen(false)}
          >
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="min-h-0 flex-1 overflow-y-auto py-1">
          {rows.map((definition) => {
            const command = definition.command;
            const chord = resolved.get(command);
            const overridden = isOverridden(command);
            const isCapturing = capturing === command;
            return (
              <div
                key={command}
                className="flex items-center gap-3 px-4 py-1.5"
                data-testid="keybindings-editor-row"
                data-command={command}
              >
                <span className="min-w-0 flex-1 truncate text-[13px] text-text-primary">
                  {definition.label}
                </span>
                {overridden ? (
                  <button
                    type="button"
                    className="rounded p-1 text-text-muted transition-colors hover:bg-[var(--color-hover-fill)]"
                    title="Reset to default"
                    aria-label={`Reset ${definition.label} to default`}
                    data-testid="keybindings-editor-reset"
                    onClick={() => resetOverride(command)}
                  >
                    <RotateCcw className="h-3.5 w-3.5" />
                  </button>
                ) : null}
                <button
                  type="button"
                  className={cn(
                    "min-w-[92px] rounded border px-2 py-1 text-center font-mono text-[11px] transition-colors",
                    isCapturing
                      ? "border-accent text-accent"
                      : "border-border-subtle bg-surface text-text-secondary hover:border-border-strong",
                  )}
                  data-testid="keybindings-editor-chord"
                  data-overridden={overridden}
                  data-capturing={isCapturing}
                  onClick={() => setCapturing(isCapturing ? null : command)}
                >
                  {isCapturing
                    ? "Press keys…"
                    : chord
                      ? formatChordString(chord, platform)
                      : "Unassigned"}
                </button>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
