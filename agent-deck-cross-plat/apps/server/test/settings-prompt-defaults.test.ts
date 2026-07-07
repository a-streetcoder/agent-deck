import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { SettingsStore } from "../src/persistence.ts";

/**
 * Default prompt-template membership (native defaultPromptTemplateNames): the
 * flat "All Projects" set that becomes `--prompt-template` launch flags. The
 * ops are atomic against current state and persist across a reload.
 */

function freshDir(): string {
  return mkdtempSync(path.join(tmpdir(), "settings-prompt-"));
}

describe("SettingsStore default prompt templates", () => {
  it("adds and removes a default, idempotently", () => {
    const dir = freshDir();
    const store = new SettingsStore(dir);
    expect(store.get().defaultPromptTemplates).toEqual([]);

    store.setDefaultPromptTemplate("review", true);
    store.setDefaultPromptTemplate("review", true); // idempotent
    store.setDefaultPromptTemplate("ship", true);
    expect(store.get().defaultPromptTemplates.sort()).toEqual(["review", "ship"]);

    store.setDefaultPromptTemplate("review", false);
    expect(store.get().defaultPromptTemplates).toEqual(["ship"]);
  });

  it("persists across a reload from the same data dir", () => {
    const dir = freshDir();
    new SettingsStore(dir).setDefaultPromptTemplate("review", true);
    // A fresh store reads the on-disk app-settings.json.
    expect(new SettingsStore(dir).get().defaultPromptTemplates).toEqual(["review"]);
  });

  it("renames a default in place, and drops it with newName=null", () => {
    const dir = freshDir();
    const store = new SettingsStore(dir);
    store.setDefaultPromptTemplate("review", true);

    store.renameDefaultPromptTemplate("review", "audit");
    expect(store.get().defaultPromptTemplates).toEqual(["audit"]);

    store.renameDefaultPromptTemplate("audit", null);
    expect(store.get().defaultPromptTemplates).toEqual([]);
  });

  it("rename/drop of a non-member is a no-op", () => {
    const dir = freshDir();
    const store = new SettingsStore(dir);
    store.setDefaultPromptTemplate("keep", true);
    store.renameDefaultPromptTemplate("absent", "whatever");
    expect(store.get().defaultPromptTemplates).toEqual(["keep"]);
  });

  it("keeps default skills and prompt templates independent", () => {
    const dir = freshDir();
    const store = new SettingsStore(dir);
    store.setDefaultSkill("a-skill", true);
    store.setDefaultPromptTemplate("a-prompt", true);
    expect(store.get().defaultSkills).toEqual(["a-skill"]);
    expect(store.get().defaultPromptTemplates).toEqual(["a-prompt"]);
    store.setDefaultPromptTemplate("a-prompt", false);
    expect(store.get().defaultSkills).toEqual(["a-skill"]); // untouched
  });
});
