import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { SettingsStore } from "../src/persistence.ts";

/**
 * Slice 14 — the keybindings overrides field on AppSettings. The store must
 * default it empty, round-trip a valid override through a flush + reload, and
 * DROP malformed/unknown entries on load (the settings PATCH refine is the other
 * gate; this pins the persistence layer's own validation).
 */

function freshDir(): string {
  return mkdtempSync(path.join(tmpdir(), "keybindings-settings-"));
}

describe("AppSettings.keybindings persistence", () => {
  it("defaults to an empty overrides list", () => {
    expect(new SettingsStore(freshDir()).get().keybindings).toEqual([]);
  });

  it("round-trips a valid override through a fresh store on the same data dir", () => {
    const dir = freshDir();
    new SettingsStore(dir).update({
      keybindings: [{ command: "terminal.toggle", key: "mod+j" }],
    });
    const reloaded = new SettingsStore(dir).get();
    expect(reloaded.keybindings).toEqual([{ command: "terminal.toggle", key: "mod+j" }]);
  });

  it("drops unknown commands and malformed chords on load", () => {
    const dir = freshDir();
    writeFileSync(
      path.join(dir, "app-settings.json"),
      JSON.stringify({
        keybindings: [
          { command: "terminal.toggle", key: "mod+j" }, // kept
          { command: "not.a.command", key: "mod+z" }, // unknown command
          { command: "session.new", key: "n" }, // bare key, no modifier
          { command: "session.stop", key: "shift+." }, // shift-only, not a real modifier
          { command: "view.git", key: "mod+g" }, // kept (default-less command, still rebindable)
          "garbage",
        ],
      }),
    );
    expect(new SettingsStore(dir).get().keybindings).toEqual([
      { command: "terminal.toggle", key: "mod+j" },
      { command: "view.git", key: "mod+g" },
    ]);
  });

  it("does not disturb other settings fields when overrides are set", () => {
    const dir = freshDir();
    const store = new SettingsStore(dir);
    store.setDefaultSkill("diagnose", true);
    store.update({ keybindings: [{ command: "diff.toggle", key: "mod+shift+d" }] });
    const reloaded = new SettingsStore(dir).get();
    expect(reloaded.defaultSkills).toEqual(["diagnose"]);
    expect(reloaded.keybindings).toEqual([{ command: "diff.toggle", key: "mod+shift+d" }]);
  });
});
