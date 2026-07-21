import { describe, expect, it } from "vitest";
import {
  chordFromEvent,
  commandForChordEvent,
  DEFAULT_KEYBINDINGS,
  findChordConflicts,
  formatChordString,
  isValidChord,
  matchesChord,
  parseChord,
  resolveKeybindings,
  type ChordEventLike,
  type KeybindingBinding,
} from "../src/keybindings.ts";

const MAC = "MacIntel";
const WIN = "Win32";

function event(overrides: Partial<ChordEventLike>): ChordEventLike {
  return {
    key: "",
    metaKey: false,
    ctrlKey: false,
    shiftKey: false,
    altKey: false,
    ...overrides,
  };
}

describe("parseChord", () => {
  it("splits modifiers from the key and normalizes aliases", () => {
    expect(parseChord("mod+k")).toEqual({
      key: "k",
      mod: true,
      meta: false,
      ctrl: false,
      shift: false,
      alt: false,
    });
    expect(parseChord("ctrl+shift+esc")).toEqual({
      key: "escape",
      mod: false,
      meta: false,
      ctrl: true,
      shift: true,
      alt: false,
    });
    // cmd/option are aliases; space is a literal key token.
    expect(parseChord("cmd+option+space")).toMatchObject({ key: " ", meta: true, alt: true });
  });

  it("treats a trailing + as the literal plus key", () => {
    expect(parseChord("mod+")).toEqual({
      key: "+",
      mod: true,
      meta: false,
      ctrl: false,
      shift: false,
      alt: false,
    });
  });

  it("rejects empty, multi-key, and malformed chords", () => {
    expect(parseChord("")).toBeNull();
    expect(parseChord("mod+a+b")).toBeNull();
    expect(parseChord("mod++k")).toBeNull();
  });
});

describe("isValidChord", () => {
  it("requires a non-shift modifier so plain typing is never hijacked", () => {
    expect(isValidChord("mod+k")).toBe(true);
    expect(isValidChord("ctrl+alt+delete")).toBe(true);
    expect(isValidChord("k")).toBe(false); // bare key
    expect(isValidChord("shift+k")).toBe(false); // shift-only
    expect(isValidChord("garbage key")).toBe(false);
  });

  it("every shipped default is a valid chord", () => {
    for (const binding of DEFAULT_KEYBINDINGS) {
      expect(isValidChord(binding.key)).toBe(true);
    }
  });
});

describe("matchesChord", () => {
  it("resolves mod to Cmd on macOS and Ctrl elsewhere", () => {
    const chord = parseChord("mod+k")!;
    expect(matchesChord(event({ key: "k", metaKey: true }), chord, MAC)).toBe(true);
    expect(matchesChord(event({ key: "k", ctrlKey: true }), chord, MAC)).toBe(false);
    expect(matchesChord(event({ key: "k", ctrlKey: true }), chord, WIN)).toBe(true);
    expect(matchesChord(event({ key: "k", metaKey: true }), chord, WIN)).toBe(false);
  });

  it("matches a digit chord through the event code even when Shift alters the key", () => {
    const chord = parseChord("mod+3")!;
    expect(matchesChord(event({ key: "#", code: "Digit3", ctrlKey: true }), chord, WIN)).toBe(true);
  });

  it("requires an exact modifier match (extra Shift does not match)", () => {
    const chord = parseChord("mod+n")!;
    expect(matchesChord(event({ key: "n", ctrlKey: true, shiftKey: true }), chord, WIN)).toBe(
      false,
    );
  });
});

describe("resolveKeybindings + commandForChordEvent", () => {
  it("applies user overrides on top of defaults and matches live", () => {
    // Rebind the terminal toggle from mod+` to mod+j.
    const overrides: KeybindingBinding[] = [{ command: "terminal.toggle", key: "mod+j" }];
    const resolved = resolveKeybindings(overrides);
    expect(resolved.get("terminal.toggle")).toBe("mod+j");
    // The default palette binding is untouched.
    expect(resolved.get("commandPalette.toggle")).toBe("mod+k");

    expect(commandForChordEvent(event({ key: "j", ctrlKey: true }), resolved, WIN)).toBe(
      "terminal.toggle",
    );
    expect(commandForChordEvent(event({ key: "k", ctrlKey: true }), resolved, WIN)).toBe(
      "commandPalette.toggle",
    );
    expect(commandForChordEvent(event({ key: "z", ctrlKey: true }), resolved, WIN)).toBeNull();
  });

  it("ignores unknown commands and unbinds on an empty override", () => {
    const resolved = resolveKeybindings([
      { command: "not-a-command" as never, key: "mod+z" },
      { command: "session.new", key: "" },
    ]);
    expect(resolved.has("session.new")).toBe(false);
    expect(commandForChordEvent(event({ key: "n", ctrlKey: true }), resolved, WIN)).toBeNull();
  });
});

describe("findChordConflicts", () => {
  it("names other commands sharing a resolved chord, honoring mod↔ctrl aliasing", () => {
    const resolved = resolveKeybindings([{ command: "diff.toggle", key: "ctrl+k" }]);
    // On Windows, mod+k (commandPalette) and ctrl+k (diff.toggle) collide.
    expect(findChordConflicts(resolved, "diff.toggle", "ctrl+k", WIN)).toContain(
      "commandPalette.toggle",
    );
    // On macOS mod resolves to Cmd, so ctrl+k does NOT collide with mod+k.
    expect(findChordConflicts(resolved, "diff.toggle", "ctrl+k", MAC)).not.toContain(
      "commandPalette.toggle",
    );
    // A free chord conflicts with nothing.
    expect(findChordConflicts(resolved, "diff.toggle", "mod+shift+f9", WIN)).toEqual([]);
  });
});

describe("chordFromEvent (editor capture)", () => {
  it("captures the platform-primary modifier as mod", () => {
    expect(chordFromEvent(event({ key: "K", metaKey: true, shiftKey: true }), MAC)).toBe(
      "mod+shift+k",
    );
    expect(chordFromEvent(event({ key: "K", ctrlKey: true, shiftKey: true }), WIN)).toBe(
      "mod+shift+k",
    );
  });

  it("returns null for a modifier-only or bare keypress", () => {
    expect(chordFromEvent(event({ key: "Shift", shiftKey: true }), WIN)).toBeNull();
    expect(chordFromEvent(event({ key: "a" }), WIN)).toBeNull();
  });
});

describe("formatChordString", () => {
  it("renders symbols on macOS and words elsewhere", () => {
    expect(formatChordString("mod+k", MAC)).toBe("⌘K");
    expect(formatChordString("mod+k", WIN)).toBe("Ctrl+K");
    expect(formatChordString("mod+shift+]", WIN)).toBe("Ctrl+Shift+]");
  });
});
