import type { ProjectMeta, SessionMeta } from "@agent-deck/contracts";
import { Cause, Effect, Option, Runtime } from "effect";
import {
  defaultDataDir,
  makeJsonArrayStoreHandle,
  makeSettingsStoreHandle,
  type AppSettings,
  type JsonArrayStoreHandle,
  type SettingsStoreHandle,
} from "./services/persistence.ts";

/**
 * App-data persistence — the synchronous class facade over the Slice 6 Effect
 * service (services/persistence.ts). pi owns the canonical session files; we keep
 * light JSON indexes (sessions, projects) and the app-settings blob that survive
 * server restarts. Writes are atomic (tmp + rename). The **on-disk JSON format and
 * file paths are unchanged** — this is the same storage, now behind a service.
 *
 * These classes keep the exact API the routes / SessionManager / server bootstrap
 * depend on, so no consumer churns in this slice (Effect-native at Slice 7). Each
 * store's real state + I/O lives in a context-free {@link JsonArrayStoreHandle} /
 * {@link SettingsStoreHandle} built by the service's `make*` effect; the facade
 * runs those effects synchronously with no ManagedRuntime (a context-free handle
 * needs none), exactly as `pushBus.ts` adapts the push-bus service. Read-only ops
 * are total, so they use `Effect.runSync` directly; every fallible write/construct
 * (the tmp+rename flush, the `mkdirSync` on open) instead goes through
 * {@link runSyncUnwrapped} so an fs error re-surfaces as the ORIGINAL Error the
 * legacy class threw — not Effect's FiberFailure wrapper — matching the same
 * unwrap the sibling `pushBus.ts` facade applies to subscriber exceptions.
 */

export { defaultDataDir };
export type { AppSettings, ImportedSkillRepository } from "./services/persistence.ts";

/**
 * `Effect.runSync`, but a defect thrown by user code inside the effect (here the
 * fs error from a `mkdirSync`/`writeFileSync`/`renameSync` on a failing flush or
 * store construction) re-surfaces as the ORIGINAL error instance, not Effect's
 * FiberFailure wrapper — the legacy classes propagated the raw fs Error straight
 * out of the constructor / upsert / update, and callsites stringify /
 * instanceof-check / `err.code`-branch on what they catch (mirrors
 * `runSyncUnwrapped` in the sibling pushBus.ts facade).
 */
function runSyncUnwrapped<A>(effect: Effect.Effect<A>): A {
  try {
    return Effect.runSync(effect);
  } catch (error) {
    if (Runtime.isFiberFailure(error)) throw Cause.squash(error[Runtime.FiberFailureCauseId]);
    throw error;
  }
}

/** Thin synchronous facade over a {@link JsonArrayStoreHandle}. */
class JsonArrayStore<T extends { id: string }> {
  private readonly handle: JsonArrayStoreHandle<T>;

  constructor(dataDir: string, fileName: string) {
    this.handle = runSyncUnwrapped(makeJsonArrayStoreHandle<T>(dataDir, fileName));
  }

  list(): T[] {
    return Effect.runSync(this.handle.list);
  }

  find(predicate: (item: T) => boolean): T | undefined {
    return Option.getOrUndefined(Effect.runSync(this.handle.find(predicate)));
  }

  upsert(item: T): void {
    runSyncUnwrapped(this.handle.upsert(item));
  }

  remove(id: string): boolean {
    return runSyncUnwrapped(this.handle.remove(id));
  }
}

export class SessionIndex extends JsonArrayStore<SessionMeta> {
  constructor(dataDir: string = defaultDataDir()) {
    super(dataDir, "sessions.json");
  }
}

export class ProjectIndex extends JsonArrayStore<ProjectMeta> {
  constructor(dataDir: string = defaultDataDir()) {
    super(dataDir, "projects.json");
  }
}

/** App-level settings (app-settings.json), atomic writes like the indexes. */
export class SettingsStore {
  private readonly handle: SettingsStoreHandle;

  constructor(dataDir: string = defaultDataDir()) {
    this.handle = runSyncUnwrapped(makeSettingsStoreHandle(dataDir));
  }

  get(): AppSettings {
    return Effect.runSync(this.handle.get);
  }

  update(patch: Partial<AppSettings>): AppSettings {
    return runSyncUnwrapped(this.handle.update(patch));
  }

  /**
   * Atomic membership ops — computed against CURRENT state so concurrent
   * clients can't clobber each other with stale whole-array replacements.
   */
  setDefaultSkill(name: string, enabled: boolean): AppSettings {
    return runSyncUnwrapped(this.handle.setDefaultSkill(name, enabled));
  }

  setDefaultPromptTemplate(name: string, enabled: boolean): AppSettings {
    return runSyncUnwrapped(this.handle.setDefaultPromptTemplate(name, enabled));
  }

  /** Rename/delete upkeep: rewrite (or drop, with newName=null) a default entry. */
  renameDefaultPromptTemplate(oldName: string, newName: string | null): AppSettings {
    return runSyncUnwrapped(this.handle.renameDefaultPromptTemplate(oldName, newName));
  }

  setDisabledSkill(name: string, disabled: boolean): AppSettings {
    return runSyncUnwrapped(this.handle.setDisabledSkill(name, disabled));
  }

  /** Add an extension path (idempotent), enabled by default. */
  addExtension(extPath: string): AppSettings {
    return runSyncUnwrapped(this.handle.addExtension(extPath));
  }

  /** Remove an extension path from both lists entirely. */
  removeExtension(extPath: string): AppSettings {
    return runSyncUnwrapped(this.handle.removeExtension(extPath));
  }

  setExtensionDisabled(extPath: string, disabled: boolean): AppSettings {
    return runSyncUnwrapped(this.handle.setExtensionDisabled(extPath, disabled));
  }

  /** Record (or replace-by-id) an imported skill repository's provenance. */
  upsertImportedSkillRepository(
    repo: AppSettings["importedSkillRepositories"][number],
  ): AppSettings {
    return runSyncUnwrapped(this.handle.upsertImportedSkillRepository(repo));
  }

  removeImportedSkillRepository(id: string): AppSettings {
    return runSyncUnwrapped(this.handle.removeImportedSkillRepository(id));
  }

  /** Hide/show a model in the picker, by its "<provider>:<id>" key. */
  setModelDisabled(key: string, disabled: boolean): AppSettings {
    return runSyncUnwrapped(this.handle.setModelDisabled(key, disabled));
  }

  /** Enabled extension paths — merged into every session launch. */
  enabledExtensions(): string[] {
    return Effect.runSync(this.handle.enabledExtensions);
  }

  /** Drop a skill name from every list (used when a skill is deleted). */
  forgetSkill(name: string): AppSettings {
    return runSyncUnwrapped(this.handle.forgetSkill(name));
  }

  /** Re-point a renamed skill in every app-level list (default + disabled). */
  renameSkill(oldName: string, newName: string): AppSettings {
    return runSyncUnwrapped(this.handle.renameSkill(oldName, newName));
  }

  /** Add or remove a discovery root (atomic membership op). */
  setProjectRoot(root: string, present: boolean): AppSettings {
    return runSyncUnwrapped(this.handle.setProjectRoot(root, present));
  }
}
