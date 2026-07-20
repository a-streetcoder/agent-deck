import { copyFileSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { ProjectMeta, SessionMeta } from "@agent-deck/domain";
import { Effect, Option } from "effect";
import { describe, expect, it } from "vitest";
import { ProjectIndex, SessionIndex, SettingsStore } from "../src/persistence.ts";
import {
  makeJsonArrayStoreHandle,
  makeSettingsStoreHandle,
  Persistence,
  PersistenceLive,
} from "../src/services/persistence.ts";

/**
 * Slice 6 hard constraint: an EXISTING on-disk data dir must load byte-identically
 * through the persistence service, and re-flushing it must reproduce the exact
 * same bytes. The fixture in fixtures/persistence/ is a realistic app-data dir
 * (populated indexes + non-default settings + an imported skill repo) whose files
 * are the canonical `JSON.stringify(x, null, 2)` the legacy class wrote. This test
 * pins that the service reads it identically and never rewrites the format.
 */

const FIXTURE_DIR = fileURLToPath(new URL("./fixtures/persistence", import.meta.url));

const readFixture = (name: string): string => readFileSync(path.join(FIXTURE_DIR, name), "utf8");

/** A temp copy of the fixture, so flush-inducing ops never touch the committed fixture. */
function freshCopy(): string {
  const dir = mkdtempSync(path.join(tmpdir(), "persist-roundtrip-"));
  for (const name of ["sessions.json", "projects.json", "app-settings.json"]) {
    copyFileSync(path.join(FIXTURE_DIR, name), path.join(dir, name));
  }
  return dir;
}

const expectedSessions: SessionMeta[] = JSON.parse(readFixture("sessions.json")) as SessionMeta[];
const expectedProjects: ProjectMeta[] = JSON.parse(readFixture("projects.json")) as ProjectMeta[];

describe("persistence service — existing-data-dir round-trip", () => {
  it("class facade loads the fixture indexes identically", () => {
    expect(new SessionIndex(FIXTURE_DIR).list()).toEqual(expectedSessions);
    expect(new ProjectIndex(FIXTURE_DIR).list()).toEqual(expectedProjects);
  });

  it("class facade loads the fixture settings identically (every field)", () => {
    const s = new SettingsStore(FIXTURE_DIR).get();
    expect(s.defaultSkills).toEqual(["diagnose", "tdd"]);
    expect(s.defaultPromptTemplates).toEqual(["review", "ship"]);
    expect(s.disabledSkills).toEqual(["legacy-skill"]);
    expect(s.projectRoots).toEqual(["/home/dev", "/work/repos"]);
    expect(s.extensions).toEqual(["/home/dev/.pi/ext/a.js", "/home/dev/.pi/ext/b.js"]);
    expect(s.disabledExtensions).toEqual(["/home/dev/.pi/ext/b.js"]);
    expect(s.disabledModels).toEqual(["anthropic:claude-legacy"]);
    expect(s.autoTitle).toBe(false);
    expect(s.worktreeIsolation).toBe(true);
    expect(s.gitAutomation).toBe(false);
    expect(s.defaultModel).toBe("anthropic:claude-opus");
    expect(s.defaultThinking).toBe("high");
    expect(s.extensionLoadingMode).toBe("agentDeckManaged");
    expect(s.importedSkillRepositories).toHaveLength(1);
    expect(s.importedSkillRepositories[0]).toMatchObject({
      id: "repo-1",
      remoteUrl: "https://github.com/acme/skills.git",
      skillNames: ["alpha", "beta"],
      lastSyncedCommit: "0123456789abcdef",
    });
    // enabledExtensions() honors the fixture's disabledExtensions.
    expect(new SettingsStore(FIXTURE_DIR).enabledExtensions()).toEqual(["/home/dev/.pi/ext/a.js"]);
  });

  it("the service handles load the fixture identically to the facade", () => {
    const sessions = Effect.runSync(
      makeJsonArrayStoreHandle<SessionMeta>(FIXTURE_DIR, "sessions.json"),
    );
    expect(Effect.runSync(sessions.list)).toEqual(expectedSessions);
    const found = Effect.runSync(sessions.find((s) => s.id === "sess-22222222"));
    expect(Option.isSome(found)).toBe(true);
    expect(Option.getOrThrow(found).id).toBe("sess-22222222");
    expect(Option.isNone(Effect.runSync(sessions.find((s) => s.id === "missing")))).toBe(true);

    const settings = Effect.runSync(makeSettingsStoreHandle(FIXTURE_DIR));
    expect(Effect.runSync(settings.get).defaultSkills).toEqual(["diagnose", "tdd"]);
  });

  it("resolves the same handles through the Persistence service tag", () => {
    const program = Effect.gen(function* () {
      const persistence = yield* Persistence;
      const sessions = yield* persistence.openSessionIndex(FIXTURE_DIR);
      const settings = yield* persistence.openSettingsStore(FIXTURE_DIR);
      return {
        sessions: yield* sessions.list,
        model: (yield* settings.get).defaultModel,
      };
    });
    const out = Effect.runSync(Effect.provide(program, PersistenceLive));
    expect(out.sessions).toEqual(expectedSessions);
    expect(out.model).toBe("anthropic:claude-opus");
  });

  it("re-flushing an unchanged store reproduces byte-identical files", () => {
    const dir = freshCopy();

    // sessions.json: upsert the loaded item back under its own id (in-place).
    const sessions = new SessionIndex(dir);
    const first = sessions.list()[0];
    expect(first).toBeDefined();
    sessions.upsert(first!);
    expect(readFileSync(path.join(dir, "sessions.json"), "utf8")).toBe(
      readFixture("sessions.json"),
    );

    // projects.json: same in-place upsert.
    const projects = new ProjectIndex(dir);
    projects.upsert(projects.list()[0]!);
    expect(readFileSync(path.join(dir, "projects.json"), "utf8")).toBe(
      readFixture("projects.json"),
    );

    // app-settings.json: an empty patch re-serializes the loaded settings.
    new SettingsStore(dir).update({});
    expect(readFileSync(path.join(dir, "app-settings.json"), "utf8")).toBe(
      readFixture("app-settings.json"),
    );
  });

  it("a settings edit persists and reloads through a fresh store (same data dir)", () => {
    const dir = freshCopy();
    new SettingsStore(dir).setDefaultSkill("newskill", true);
    const reloaded = new SettingsStore(dir).get();
    expect(reloaded.defaultSkills).toContain("newskill");
    // The pre-existing fields are untouched by the membership op.
    expect(reloaded.defaultModel).toBe("anthropic:claude-opus");
    expect(reloaded.importedSkillRepositories).toHaveLength(1);
  });
});
