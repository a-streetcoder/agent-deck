import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { SettingsStore } from "../src/persistence.ts";

/**
 * Onboarding-preferences settings (native OnboardingPreferencesView): autoTitle,
 * worktreeIsolation, gitAutomation, defaultModel, defaultThinking. Defaults match
 * native, round-trip through app-settings.json, and a corrupt/mistyped file falls
 * back to the defaults per field (never throws).
 */

function freshDir(): string {
  return mkdtempSync(path.join(tmpdir(), "settings-prefs-"));
}

describe("SettingsStore onboarding preferences", () => {
  it("defaults to native's values", () => {
    const s = new SettingsStore(freshDir()).get();
    expect(s.autoTitle).toBe(true);
    expect(s.worktreeIsolation).toBe(false);
    expect(s.gitAutomation).toBe(true);
    expect(s.defaultModel).toBeNull();
    expect(s.defaultThinking).toBeNull();
    expect(s.extensionLoadingMode).toBe("useMyExtensions");
    expect(s.importedSkillRepositories).toEqual([]);
  });

  it("round-trips every field across a reload", () => {
    const dir = freshDir();
    new SettingsStore(dir).update({
      autoTitle: false,
      worktreeIsolation: true,
      gitAutomation: true,
      defaultModel: "gpt-5.5",
      defaultThinking: "high",
      extensionLoadingMode: "agentDeckManaged",
    });
    const reloaded = new SettingsStore(dir).get();
    expect(reloaded.autoTitle).toBe(false);
    expect(reloaded.worktreeIsolation).toBe(true);
    expect(reloaded.gitAutomation).toBe(true);
    expect(reloaded.defaultModel).toBe("gpt-5.5");
    expect(reloaded.defaultThinking).toBe("high");
    expect(reloaded.extensionLoadingMode).toBe("agentDeckManaged");
    // Untouched arrays are preserved (the patch never clobbers them).
    expect(reloaded.defaultSkills).toEqual([]);
  });

  it("clears defaultModel/defaultThinking back to null", () => {
    const dir = freshDir();
    const store = new SettingsStore(dir);
    store.update({ defaultModel: "gpt-5.5", defaultThinking: "low" });
    store.update({ defaultModel: null, defaultThinking: null });
    const s = new SettingsStore(dir).get();
    expect(s.defaultModel).toBeNull();
    expect(s.defaultThinking).toBeNull();
  });

  it("falls back to defaults for a mistyped/corrupt file, per field", () => {
    const dir = freshDir();
    writeFileSync(
      path.join(dir, "app-settings.json"),
      JSON.stringify({
        autoTitle: "yes", // not a boolean → default true
        worktreeIsolation: 1, // not a boolean → default false
        defaultModel: 42, // not a string → null
        defaultThinking: "bogus", // not a real level → null
        defaultSkills: ["keep"], // a valid field is still read
      }),
    );
    const s = new SettingsStore(dir).get();
    expect(s.autoTitle).toBe(true);
    expect(s.worktreeIsolation).toBe(false);
    expect(s.gitAutomation).toBe(true);
    expect(s.defaultModel).toBeNull();
    expect(s.defaultThinking).toBeNull();
    expect(s.defaultSkills).toEqual(["keep"]);
  });
});
