/**
 * Keybindings core (Slice 14) — the pure, platform-agnostic model shared by the
 * server (chord validation on the settings store) and the web app (live shortcut
 * matching, the command palette shortcut hints, and the keybindings editor).
 *
 * Pattern-ported from the t3code donor (apps/web/src/keybindings.ts +
 * packages/shared/src/keybindings.ts, MIT), deliberately SIMPLIFIED to a
 * `command → chord` map. Each of our actions carries a FIXED focus guard in the
 * web command catalog (only `terminal.toggle` fires while the terminal owns
 * focus), so the donor's user-editable `when` expression grammar is dropped: the
 * user only edits the chord. A "chord" is a `+`-joined string like `mod+k` or
 * `mod+shift+]`; `mod` is the platform primary modifier (⌘ on macOS, Ctrl on
 * Windows/Linux — our ship targets).
 *
 * No runtime deps and no DOM types (the server imports this): event-shaped
 * inputs are plain interfaces and the platform is always passed explicitly.
 */

export const KEYBINDING_COMMANDS = [
  // Global actions
  "commandPalette.toggle",
  "terminal.toggle",
  "diff.toggle",
  "files.toggle",
  "preview.toggle",
  "session.new",
  "session.stop",
  "session.next",
  "session.previous",
  "panel.sessions.toggle",
  "keybindings.open",
  // Navigation — one per AppView reachable from the sidebar / chat surface.
  "view.chat",
  "view.projects",
  "view.instructions",
  "view.issues",
  "view.git",
  "view.agents",
  "view.skills",
  "view.loops",
  "view.prompts",
  "view.memory",
  "view.models",
  "view.providers",
  "view.environment",
  "view.extensions",
  "view.mcp",
  "view.doctor",
] as const;
export type KeybindingCommand = (typeof KEYBINDING_COMMANDS)[number];

const KEYBINDING_COMMAND_SET: ReadonlySet<string> = new Set(KEYBINDING_COMMANDS);

export function isKeybindingCommand(value: string): value is KeybindingCommand {
  return KEYBINDING_COMMAND_SET.has(value);
}

export const MAX_KEYBINDING_CHORD_LENGTH = 64;
/** Guard against an unbounded overrides array reaching the store. */
export const MAX_KEYBINDINGS_COUNT = 128;

/** One user binding override persisted in AppSettings: command → chord string. */
export interface KeybindingBinding {
  command: KeybindingCommand;
  key: string;
}

/**
 * The shipped defaults: the donor's chords where they exist, unified with the
 * shortcuts Agent Deck already had (terminal `mod+` ``, nav `mod+1..6`, new
 * `mod+n`, stop `mod+.`, next/prev `mod+]`/`mod+[`, sessions panel `mod+s`) plus
 * the new palette `mod+k`. Commands absent here are palette-only (no chord until
 * the user binds one).
 */
export const DEFAULT_KEYBINDINGS: readonly KeybindingBinding[] = [
  { command: "commandPalette.toggle", key: "mod+k" },
  { command: "terminal.toggle", key: "mod+`" },
  { command: "session.new", key: "mod+n" },
  { command: "session.stop", key: "mod+." },
  { command: "session.next", key: "mod+]" },
  { command: "session.previous", key: "mod+[" },
  { command: "panel.sessions.toggle", key: "mod+s" },
  { command: "view.chat", key: "mod+1" },
  { command: "view.projects", key: "mod+2" },
  { command: "view.issues", key: "mod+3" },
  { command: "view.agents", key: "mod+4" },
  { command: "view.skills", key: "mod+5" },
  { command: "view.prompts", key: "mod+6" },
];

export interface ParsedChord {
  /** Normalized key: a lowercased single char, or `escape`/`arrowup`/`f5`/… */
  readonly key: string;
  /** Platform primary modifier (⌘ on macOS, Ctrl elsewhere). */
  readonly mod: boolean;
  readonly meta: boolean;
  readonly ctrl: boolean;
  readonly shift: boolean;
  readonly alt: boolean;
}

function isMacPlatform(platform: string): boolean {
  return /mac|iphone|ipad|ipod/i.test(platform);
}

function normalizeKeyToken(token: string): string {
  if (token === "space") return " ";
  if (token === "esc") return "escape";
  return token;
}

/**
 * Parse a chord string into its modifier/key parts, or `null` if malformed.
 * Handles a trailing `+` meaning the literal "+" key (donor semantics).
 */
export function parseChord(value: string): ParsedChord | null {
  if (value.trim().length === 0) return null;
  const rawTokens = value
    .toLowerCase()
    .split("+")
    .map((token) => token.trim());
  const tokens = [...rawTokens];
  let trailingEmptyCount = 0;
  while (tokens[tokens.length - 1] === "") {
    trailingEmptyCount += 1;
    tokens.pop();
  }
  if (trailingEmptyCount > 0) {
    tokens.push("+");
  }
  if (tokens.length === 0 || tokens.some((token) => token.length === 0)) {
    return null;
  }

  let key: string | null = null;
  let meta = false;
  let ctrl = false;
  let shift = false;
  let alt = false;
  let mod = false;

  for (const token of tokens) {
    switch (token) {
      case "cmd":
      case "meta":
        meta = true;
        break;
      case "ctrl":
      case "control":
        ctrl = true;
        break;
      case "shift":
        shift = true;
        break;
      case "alt":
      case "option":
        alt = true;
        break;
      case "mod":
        mod = true;
        break;
      default: {
        if (key !== null) return null;
        key = normalizeKeyToken(token);
      }
    }
  }

  if (key === null) return null;
  return { key, mod, meta, ctrl, shift, alt };
}

/**
 * A chord is valid to persist if it parses, fits the length cap, and carries at
 * least one non-shift modifier — a bare or shift-only chord would hijack plain
 * typing, so the editor and the settings store both reject it.
 */
export function isValidChord(value: string): boolean {
  if (value.length === 0 || value.length > MAX_KEYBINDING_CHORD_LENGTH) return false;
  const parsed = parseChord(value);
  if (!parsed) return false;
  return parsed.mod || parsed.meta || parsed.ctrl || parsed.alt;
}

export interface ChordEventLike {
  readonly key: string;
  readonly code?: string;
  readonly metaKey: boolean;
  readonly ctrlKey: boolean;
  readonly shiftKey: boolean;
  readonly altKey: boolean;
}

const EVENT_CODE_KEY_ALIASES: Readonly<Record<string, string>> = {
  BracketLeft: "[",
  BracketRight: "]",
  Backquote: "`",
  Period: ".",
  Digit0: "0",
  Digit1: "1",
  Digit2: "2",
  Digit3: "3",
  Digit4: "4",
  Digit5: "5",
  Digit6: "6",
  Digit7: "7",
  Digit8: "8",
  Digit9: "9",
};

function normalizeEventKey(key: string): string {
  const normalized = key.toLowerCase();
  return normalized === "esc" ? "escape" : normalized;
}

/**
 * The set of key tokens an event could satisfy: its `key` plus code-derived
 * aliases (a `KeyJ` code maps to `j` even under a non-US layout; `Digit3`/
 * `BracketRight` map to their base symbol so `mod+3` / `mod+]` match through a
 * Shift-produced key). Ported from the donor's resolveEventKeys.
 */
function eventKeyCandidates(event: ChordEventLike): ReadonlySet<string> {
  const keys = new Set([normalizeEventKey(event.key)]);
  const letterCode = event.code?.match(/^Key([A-Z])$/)?.[1];
  if (letterCode) keys.add(letterCode.toLowerCase());
  const alias = event.code ? EVENT_CODE_KEY_ALIASES[event.code] : undefined;
  if (alias) keys.add(alias);
  return keys;
}

export function matchesChord(event: ChordEventLike, chord: ParsedChord, platform: string): boolean {
  const useMeta = isMacPlatform(platform);
  const expectedMeta = chord.meta || (chord.mod && useMeta);
  const expectedCtrl = chord.ctrl || (chord.mod && !useMeta);
  if (event.metaKey !== expectedMeta) return false;
  if (event.ctrlKey !== expectedCtrl) return false;
  if (event.shiftKey !== chord.shift) return false;
  if (event.altKey !== chord.alt) return false;
  return eventKeyCandidates(event).has(chord.key);
}

/**
 * A platform-resolved identity for a chord: two chords collide iff their
 * identities are equal (so `mod` and its resolved `meta`/`ctrl` alias share one
 * key). Used for both conflict detection and live matching de-dup.
 */
export function chordConflictKey(chord: ParsedChord, platform: string): string {
  const useMeta = isMacPlatform(platform);
  const meta = chord.meta || (chord.mod && useMeta);
  const ctrl = chord.ctrl || (chord.mod && !useMeta);
  return [
    chord.key,
    meta ? "M" : "",
    ctrl ? "C" : "",
    chord.shift ? "S" : "",
    chord.alt ? "A" : "",
  ].join("|");
}

/**
 * Seed a `command → chord` map from the defaults, then apply the user's
 * overrides on top (a later entry wins; an empty-string override unbinds). The
 * resolved map is what the live handler and the editor read.
 */
export function resolveKeybindings(
  overrides: readonly KeybindingBinding[],
): Map<KeybindingCommand, string> {
  const map = new Map<KeybindingCommand, string>();
  for (const binding of DEFAULT_KEYBINDINGS) map.set(binding.command, binding.key);
  for (const binding of overrides) {
    if (!isKeybindingCommand(binding.command)) continue;
    if (binding.key.length === 0) map.delete(binding.command);
    else map.set(binding.command, binding.key);
  }
  return map;
}

/**
 * The command whose resolved chord matches this event, or `null`. When two
 * commands resolve to the same chord the first in insertion order (defaults
 * before overrides) wins — deterministic, and our defaults never collide.
 */
export function commandForChordEvent(
  event: ChordEventLike,
  resolved: ReadonlyMap<KeybindingCommand, string>,
  platform: string,
): KeybindingCommand | null {
  for (const [command, value] of resolved) {
    const chord = parseChord(value);
    if (chord && matchesChord(event, chord, platform)) return command;
  }
  return null;
}

/**
 * Commands (other than `command`) whose resolved chord collides with `chord` —
 * the editor's conflict list and the warn-on-rebind toast source.
 */
export function findChordConflicts(
  resolved: ReadonlyMap<KeybindingCommand, string>,
  command: KeybindingCommand,
  chord: string,
  platform: string,
): KeybindingCommand[] {
  const parsed = parseChord(chord);
  if (!parsed) return [];
  const identity = chordConflictKey(parsed, platform);
  const conflicts: KeybindingCommand[] = [];
  for (const [otherCommand, otherValue] of resolved) {
    if (otherCommand === command) continue;
    const otherChord = parseChord(otherValue);
    if (otherChord && chordConflictKey(otherChord, platform) === identity) {
      conflicts.push(otherCommand);
    }
  }
  return conflicts;
}

function formatChordKeyLabel(key: string): string {
  if (key === " ") return "Space";
  if (key.length === 1) return key.toUpperCase();
  switch (key) {
    case "escape":
      return "Esc";
    case "arrowup":
      return "Up";
    case "arrowdown":
      return "Down";
    case "arrowleft":
      return "Left";
    case "arrowright":
      return "Right";
    default:
      return key.slice(0, 1).toUpperCase() + key.slice(1);
  }
}

/** A human label for a parsed chord: `⌘K` on macOS, `Ctrl+K` elsewhere. */
export function formatChord(chord: ParsedChord, platform: string): string {
  const keyLabel = formatChordKeyLabel(chord.key);
  const useMeta = isMacPlatform(platform);
  const showMeta = chord.meta || (chord.mod && useMeta);
  const showCtrl = chord.ctrl || (chord.mod && !useMeta);

  if (useMeta) {
    return `${showCtrl ? "⌃" : ""}${chord.alt ? "⌥" : ""}${chord.shift ? "⇧" : ""}${
      showMeta ? "⌘" : ""
    }${keyLabel}`;
  }

  const parts: string[] = [];
  if (showCtrl) parts.push("Ctrl");
  if (chord.alt) parts.push("Alt");
  if (chord.shift) parts.push("Shift");
  if (showMeta) parts.push("Meta");
  parts.push(keyLabel);
  return parts.join("+");
}

/** Format a raw chord string, echoing it verbatim if it fails to parse. */
export function formatChordString(value: string, platform: string): string {
  const parsed = parseChord(value);
  return parsed ? formatChord(parsed, platform) : value;
}

function normalizeCaptureKeyToken(key: string): string | null {
  const normalized = key.toLowerCase();
  switch (normalized) {
    case "meta":
    case "control":
    case "ctrl":
    case "shift":
    case "alt":
    case "option":
      return null;
    case " ":
      return "space";
    case "escape":
      return "esc";
    case "arrowup":
    case "arrowdown":
    case "arrowleft":
    case "arrowright":
    case "enter":
    case "tab":
    case "backspace":
    case "delete":
    case "home":
    case "end":
    case "pageup":
    case "pagedown":
      return normalized;
    default:
      if (normalized.length === 1) return normalized;
      if (/^f\d{1,2}$/.test(normalized)) return normalized;
      return null;
  }
}

/**
 * Turn a captured keydown into a chord string (`mod+shift+k`), or `null` if the
 * event is a bare key / modifiers only. Emits the platform-primary modifier as
 * `mod` so a binding captured on one OS reads correctly on the other.
 */
export function chordFromEvent(event: ChordEventLike, platform: string): string | null {
  const keyToken = normalizeCaptureKeyToken(event.key);
  if (!keyToken) return null;

  const parts: string[] = [];
  if (isMacPlatform(platform)) {
    if (event.metaKey) parts.push("mod");
    if (event.ctrlKey) parts.push("ctrl");
  } else {
    if (event.ctrlKey) parts.push("mod");
    if (event.metaKey) parts.push("meta");
  }
  if (event.altKey) parts.push("alt");
  if (event.shiftKey) parts.push("shift");
  if (parts.length === 0) return null;
  parts.push(keyToken);
  return parts.join("+");
}
