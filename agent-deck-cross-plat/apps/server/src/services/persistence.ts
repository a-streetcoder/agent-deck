import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import path from "node:path";
import envPaths from "env-paths";
import type { KeybindingBinding, ProjectMeta, SessionMeta } from "@agent-deck/contracts";
import { isKeybindingCommand, isValidChord } from "@agent-deck/contracts";
import { THINKING_LEVELS, type ThinkingLevel } from "@agent-deck/domain";
import { Context, Effect, Layer, Option } from "effect";

/**
 * App-data persistence as an Effect service (Slice 6 — the last Phase-2 leaf).
 * pi owns the canonical session files; we keep light JSON indexes (sessions,
 * projects) plus the app-settings blob that survive server restarts. Writes are
 * atomic (tmp + rename). The **on-disk JSON format and file paths are unchanged**
 * from the pre-migration class implementation — this slice moves the code behind
 * a service interface, not a byte on disk (a fixture round-trip test in
 * test/persistence-roundtrip.test.ts pins that).
 *
 * File anatomy (the pushBus.ts template):
 *   1. data types + handle interfaces (the effectful API surface)
 *   2. `make*` effect(s) building each handle (context-free — a handle needs
 *      only a data dir, no other service)
 *   3. `Context.Tag` service class (`Persistence`, t3code's Services/ role) — a
 *      FACTORY service, since stores are opened per data dir, not global
 *   4. `PersistenceLive` Layer (t3code's Layers/ role) — joined into
 *      `serverLayers` in ../runtime.ts
 *
 * ## Leaf service; the class facade reads through `make*` directly
 *
 * Like Slice 3's push bus, each handle is CONTEXT-FREE: `makeJsonArrayStoreHandle`
 * / `makeSettingsStoreHandle` need no other service, only a data dir. So the
 * synchronous class facade in ../persistence.ts builds its handle with
 * `Effect.runSync(make*)` directly — a total run, no ManagedRuntime required —
 * exactly as `pushBus.ts` does for the bus. The {@link Persistence} service here
 * is the composition-root seam (joined into `serverLayers`) that a future
 * Effect-native consumer (Slice 7's routes, an Effect SessionManager) resolves
 * instead of `new SessionIndex()`. Until then it is a wired-but-quiet leaf, the
 * same transitional posture the push bus held between Slice 3 and Slice 5.
 *
 * ## Template caveats (Option, no runSync in service logic)
 *
 *   - `find` returns `Option<T>`, not the legacy `T | undefined` sentinel; the
 *     class facade maps back with `Option.getOrUndefined`.
 *   - No `Effect.runSync` appears in this module — every operation is an Effect;
 *     only the class facade (../persistence.ts) runs them synchronously.
 *   - ERROR CHANNEL is deliberately `E = never` for now: the write paths
 *     (`flush`, the `mkdir` in each `make*`) do real fs I/O inside `Effect.sync`,
 *     so a disk failure (ENOSPC/EACCES/EROFS) surfaces as a DEFECT, not a typed
 *     error. This is a KNOWN divergence from the piHost precedent (which models
 *     fallible I/O with tagged errors), and unlike piHost it is safe TODAY only
 *     because the sole consumer is the synchronous facade, whose
 *     `runSyncUnwrapped` re-throws the raw fs Error with its `code` intact
 *     (parity with the legacy classes — no route inspects `err.code`). When
 *     Slice 7 makes routes Effect-native and a program does `yield* settings.update(...)`,
 *     an uncatchable defect is wrong: the flush/mkdir paths must move to
 *     `Effect.try` with a `PersistenceWriteError` tagged error that the route
 *     layer maps to an HTTP 5xx. Deferred to Slice 7 (tracked in the plan) so the
 *     error shape is designed WITH its first real consumer, not speculatively.
 */

export function defaultDataDir(): string {
  return envPaths("agent-deck-cross-plat", { suffix: "" }).data;
}

// ---------------------------------------------------------------------------
// 1. Handle interfaces (the effectful API surface)
// ---------------------------------------------------------------------------

/** One light JSON array index (sessions.json / projects.json), keyed by `id`. */
export interface JsonArrayStoreHandle<T extends { id: string }> {
  /** The live in-memory list (same reference semantics as the legacy class). */
  readonly list: Effect.Effect<T[]>;
  /** First item matching the predicate, or `None`. */
  readonly find: (predicate: (item: T) => boolean) => Effect.Effect<Option.Option<T>>;
  /** Insert or replace by `id`, then atomically flush. */
  readonly upsert: (item: T) => Effect.Effect<void>;
  /** Remove by `id`; resolves to whether anything was removed. Flushes on hit. */
  readonly remove: (id: string) => Effect.Effect<boolean>;
}

export type SessionIndexHandle = JsonArrayStoreHandle<SessionMeta>;
export type ProjectIndexHandle = JsonArrayStoreHandle<ProjectMeta>;

/**
 * Provenance for a git-imported skill repository (native ImportedSkillRepository):
 * the persistent clone kept so the repo can be re-synced, plus which skills came
 * from it and the commit they're at. There is no on-disk lockfile — this record
 * (persisted in AppSettings) IS the manifest.
 */
export interface ImportedSkillRepository {
  id: string;
  /** The clone URL (for ls-remote update checks). */
  remoteUrl: string;
  /** The tracked branch, when the import pinned one. */
  ref?: string;
  /** A repo subdirectory the import was scoped to (a deep link), if any. */
  subdir?: string;
  /** Where the imported skills landed. */
  scope: "global" | "project";
  /** For project scope: the project the skills were imported into. */
  projectPath?: string;
  /** The persistent clone dir, re-fetched on update. */
  clonePath: string;
  /** The catalog skill names imported from this repo. */
  skillNames: string[];
  /**
   * The as-written SKILL.md fingerprint per skill name (native conflict
   * detection): if the catalog copy's current hash differs on update, the user
   * edited it locally → a conflict to resolve rather than silently overwrite.
   */
  skillHashes?: Record<string, string>;
  /** The clone's HEAD commit at the last successful sync. */
  lastSyncedCommit: string;
  importedAt: string;
}

export interface AppSettings {
  /** Skills injected into EVERY project's parent sessions ("All Projects"). */
  defaultSkills: string[];
  /**
   * Prompt templates made available in EVERY project's parent sessions as
   * `--prompt-template` flags ("All Projects"). Native defaultPromptTemplateNames.
   */
  defaultPromptTemplates: string[];
  /** Skills the user turned off: unassignable, excluded from --skill injection. */
  disabledSkills: string[];
  /** Root folders scanned for project auto-discovery. */
  projectRoots: string[];
  /** Extension files (absolute paths) the user added to load into sessions. */
  extensions: string[];
  /** Extensions turned off: kept in the list but excluded from --extension. */
  disabledExtensions: string[];
  /** Models the user hid from the picker, by "<provider>:<id>" key. */
  disabledModels: string[];
  /**
   * Onboarding-preferences (native OnboardingPreferencesView). `defaultModel`
   * (provider-qualified "provider:id" so it launches under the right provider) /
   * `defaultThinking` seed every NEW parent ("All Projects" / Pi Agent) session's
   * launch when the request doesn't override them; `autoTitle` gates the
   * title-helper launch; `worktreeIsolation` runs each session in its own git
   * worktree; `gitAutomation` gates the Git screen's Commit/Push/Merge actions.
   */
  autoTitle: boolean;
  worktreeIsolation: boolean;
  gitAutomation: boolean;
  defaultModel: string | null;
  defaultThinking: ThinkingLevel | null;
  /**
   * How pi extensions load (native PiAgentExtensionLoadingMode). "useMyExtensions"
   * loads the user's discovered/added enabled extensions alongside Agent Deck's
   * bridges; "agentDeckManaged" loads ONLY the bridges (the user's Pi extensions
   * stay off, though still listed). Native defaults to agentDeckManaged; the port
   * keeps its shipped default of loading discovered extensions and offers the
   * stricter mode as an opt-in.
   */
  extensionLoadingMode: "useMyExtensions" | "agentDeckManaged";
  /** Provenance for git-imported skill repos (native importedSkillRepositories). */
  importedSkillRepositories: ImportedSkillRepository[];
  /**
   * The remembered open-in-editor choice (Slice 11): the editor id last picked
   * from the diff panel's picker, so the next open is one click. An id, never
   * a command — the server only launches editors from its own detected list.
   */
  preferredEditor: string | null;
  /**
   * User keybinding overrides (Slice 14): a `command -> chord` list layered over
   * the shipped `DEFAULT_KEYBINDINGS`. Empty = all defaults. Each entry is
   * validated on load and on PATCH (known command + a chord with a real
   * modifier); anything else is dropped rather than trusted.
   */
  keybindings: KeybindingBinding[];
}

/** Keep only well-formed overrides (known command + a valid, modifier-bearing chord). */
function coerceKeybindings(value: unknown): KeybindingBinding[] {
  if (!Array.isArray(value)) return [];
  const out: KeybindingBinding[] = [];
  for (const entry of value) {
    if (typeof entry !== "object" || entry === null) continue;
    const record = entry as { command?: unknown; key?: unknown };
    if (typeof record.command !== "string" || typeof record.key !== "string") continue;
    if (!isKeybindingCommand(record.command) || !isValidChord(record.key)) continue;
    out.push({ command: record.command, key: record.key });
  }
  return out;
}

/** App-level settings (app-settings.json); the effectful surface of the store. */
export interface SettingsStoreHandle {
  readonly get: Effect.Effect<AppSettings>;
  readonly update: (patch: Partial<AppSettings>) => Effect.Effect<AppSettings>;
  readonly setDefaultSkill: (name: string, enabled: boolean) => Effect.Effect<AppSettings>;
  readonly setDefaultPromptTemplate: (name: string, enabled: boolean) => Effect.Effect<AppSettings>;
  readonly renameDefaultPromptTemplate: (
    oldName: string,
    newName: string | null,
  ) => Effect.Effect<AppSettings>;
  readonly setDisabledSkill: (name: string, disabled: boolean) => Effect.Effect<AppSettings>;
  readonly addExtension: (extPath: string) => Effect.Effect<AppSettings>;
  readonly removeExtension: (extPath: string) => Effect.Effect<AppSettings>;
  readonly setExtensionDisabled: (extPath: string, disabled: boolean) => Effect.Effect<AppSettings>;
  readonly upsertImportedSkillRepository: (
    repo: ImportedSkillRepository,
  ) => Effect.Effect<AppSettings>;
  readonly removeImportedSkillRepository: (id: string) => Effect.Effect<AppSettings>;
  readonly setModelDisabled: (key: string, disabled: boolean) => Effect.Effect<AppSettings>;
  readonly enabledExtensions: Effect.Effect<string[]>;
  readonly forgetSkill: (name: string) => Effect.Effect<AppSettings>;
  readonly renameSkill: (oldName: string, newName: string) => Effect.Effect<AppSettings>;
  readonly setProjectRoot: (root: string, present: boolean) => Effect.Effect<AppSettings>;
}

// ---------------------------------------------------------------------------
// 2. `make*` effects (context-free — a data dir is all a handle needs)
// ---------------------------------------------------------------------------

/**
 * Build one JSON-array store handle. Reads the file on construction (missing or
 * corrupt → empty), keeps the items in closure-scoped state, and flushes with a
 * tmp + rename atomic write — byte-identical to the legacy `JsonArrayStore`.
 */
export const makeJsonArrayStoreHandle = <T extends { id: string }>(
  dataDir: string,
  fileName: string,
): Effect.Effect<JsonArrayStoreHandle<T>> =>
  Effect.sync(() => {
    const file = path.join(dataDir, fileName);
    mkdirSync(dataDir, { recursive: true });
    let items: T[] = [];
    try {
      const parsed: unknown = JSON.parse(readFileSync(file, "utf8"));
      if (Array.isArray(parsed)) items = parsed as T[];
    } catch {
      // Missing or corrupt index — start fresh.
    }

    const flush = (): void => {
      const tmp = `${file}.tmp`;
      writeFileSync(tmp, JSON.stringify(items, null, 2));
      renameSync(tmp, file);
    };

    return {
      list: Effect.sync(() => items),
      find: (predicate) => Effect.sync(() => Option.fromNullable(items.find(predicate))),
      upsert: (item) =>
        Effect.sync(() => {
          const index = items.findIndex((existing) => existing.id === item.id);
          if (index === -1) items.push(item);
          else items[index] = item;
          flush();
        }),
      remove: (id) =>
        Effect.sync(() => {
          const index = items.findIndex((existing) => existing.id === id);
          if (index === -1) return false;
          items.splice(index, 1);
          flush();
          return true;
        }),
    } satisfies JsonArrayStoreHandle<T>;
  });

/**
 * Build the app-settings store handle. The per-field load validation, the
 * default seed, the atomic membership ops, and the tmp + rename flush are all
 * byte-identical to the legacy `SettingsStore` — only the surface is now
 * effectful.
 */
export const makeSettingsStoreHandle = (dataDir: string): Effect.Effect<SettingsStoreHandle> =>
  Effect.sync(() => {
    const file = path.join(dataDir, "app-settings.json");
    mkdirSync(dataDir, { recursive: true });

    let settings: AppSettings = {
      defaultSkills: [],
      defaultPromptTemplates: [],
      disabledSkills: [],
      projectRoots: [],
      extensions: [],
      disabledExtensions: [],
      disabledModels: [],
      autoTitle: true, // native default: sessions are auto-titled by the helper
      worktreeIsolation: false,
      gitAutomation: true, // native piAgentGitAutomationEnabled default: git actions shown
      defaultModel: null,
      defaultThinking: null,
      extensionLoadingMode: "useMyExtensions", // port default: load discovered extensions
      importedSkillRepositories: [],
      preferredEditor: null,
      keybindings: [],
    };

    try {
      const parsed: unknown = JSON.parse(readFileSync(file, "utf8"));
      if (typeof parsed === "object" && parsed !== null) {
        const record = parsed as Partial<AppSettings>;
        settings = {
          defaultSkills: Array.isArray(record.defaultSkills)
            ? record.defaultSkills.map(String)
            : [],
          defaultPromptTemplates: Array.isArray(record.defaultPromptTemplates)
            ? record.defaultPromptTemplates.map(String)
            : [],
          disabledSkills: Array.isArray(record.disabledSkills)
            ? record.disabledSkills.map(String)
            : [],
          projectRoots: Array.isArray(record.projectRoots) ? record.projectRoots.map(String) : [],
          extensions: Array.isArray(record.extensions) ? record.extensions.map(String) : [],
          disabledExtensions: Array.isArray(record.disabledExtensions)
            ? record.disabledExtensions.map(String)
            : [],
          disabledModels: Array.isArray(record.disabledModels)
            ? record.disabledModels.map(String)
            : [],
          // Booleans default to the native defaults when absent/mistyped.
          autoTitle: typeof record.autoTitle === "boolean" ? record.autoTitle : true,
          worktreeIsolation:
            typeof record.worktreeIsolation === "boolean" ? record.worktreeIsolation : false,
          gitAutomation: typeof record.gitAutomation === "boolean" ? record.gitAutomation : true,
          defaultModel: typeof record.defaultModel === "string" ? record.defaultModel : null,
          defaultThinking:
            typeof record.defaultThinking === "string" &&
            (THINKING_LEVELS as readonly string[]).includes(record.defaultThinking)
              ? (record.defaultThinking as ThinkingLevel)
              : null,
          extensionLoadingMode:
            record.extensionLoadingMode === "agentDeckManaged"
              ? "agentDeckManaged"
              : "useMyExtensions",
          importedSkillRepositories: Array.isArray(record.importedSkillRepositories)
            ? (record.importedSkillRepositories as ImportedSkillRepository[])
            : [],
          preferredEditor:
            typeof record.preferredEditor === "string" ? record.preferredEditor : null,
          keybindings: coerceKeybindings(record.keybindings),
        };
      }
    } catch {
      // Missing or corrupt — defaults apply.
    }

    const flush = (): void => {
      const tmp = `${file}.tmp`;
      writeFileSync(tmp, JSON.stringify(settings, null, 2));
      renameSync(tmp, file);
    };

    return {
      get: Effect.sync(() => settings),
      update: (patch) =>
        Effect.sync(() => {
          settings = { ...settings, ...patch };
          flush();
          return settings;
        }),
      setDefaultSkill: (name, enabled) =>
        Effect.sync(() => {
          const next = new Set(settings.defaultSkills);
          if (enabled) next.add(name);
          else next.delete(name);
          settings = { ...settings, defaultSkills: [...next] };
          flush();
          return settings;
        }),
      setDefaultPromptTemplate: (name, enabled) =>
        Effect.sync(() => {
          const next = new Set(settings.defaultPromptTemplates);
          if (enabled) next.add(name);
          else next.delete(name);
          settings = { ...settings, defaultPromptTemplates: [...next] };
          flush();
          return settings;
        }),
      renameDefaultPromptTemplate: (oldName, newName) =>
        Effect.sync(() => {
          const next = new Set(settings.defaultPromptTemplates);
          if (!next.has(oldName)) return settings;
          next.delete(oldName);
          if (newName !== null) next.add(newName);
          settings = { ...settings, defaultPromptTemplates: [...next] };
          flush();
          return settings;
        }),
      setDisabledSkill: (name, disabled) =>
        Effect.sync(() => {
          const next = new Set(settings.disabledSkills);
          if (disabled) next.add(name);
          else next.delete(name);
          // A disabled skill can't also be a default.
          const defaults = new Set(settings.defaultSkills);
          if (disabled) defaults.delete(name);
          settings = {
            ...settings,
            defaultSkills: [...defaults],
            disabledSkills: [...next],
          };
          flush();
          return settings;
        }),
      addExtension: (extPath) =>
        Effect.sync(() => {
          const next = new Set(settings.extensions);
          next.add(extPath);
          settings = { ...settings, extensions: [...next] };
          flush();
          return settings;
        }),
      removeExtension: (extPath) =>
        Effect.sync(() => {
          settings = {
            ...settings,
            extensions: settings.extensions.filter((p) => p !== extPath),
            disabledExtensions: settings.disabledExtensions.filter((p) => p !== extPath),
          };
          flush();
          return settings;
        }),
      setExtensionDisabled: (extPath, disabled) =>
        Effect.sync(() => {
          const next = new Set(settings.disabledExtensions);
          if (disabled) next.add(extPath);
          else next.delete(extPath);
          settings = { ...settings, disabledExtensions: [...next] };
          flush();
          return settings;
        }),
      upsertImportedSkillRepository: (repo) =>
        Effect.sync(() => {
          const rest = settings.importedSkillRepositories.filter((r) => r.id !== repo.id);
          settings = { ...settings, importedSkillRepositories: [...rest, repo] };
          flush();
          return settings;
        }),
      removeImportedSkillRepository: (id) =>
        Effect.sync(() => {
          settings = {
            ...settings,
            importedSkillRepositories: settings.importedSkillRepositories.filter(
              (r) => r.id !== id,
            ),
          };
          flush();
          return settings;
        }),
      setModelDisabled: (key, disabled) =>
        Effect.sync(() => {
          const next = new Set(settings.disabledModels);
          if (disabled) next.add(key);
          else next.delete(key);
          settings = { ...settings, disabledModels: [...next] };
          flush();
          return settings;
        }),
      enabledExtensions: Effect.sync(() => {
        const disabled = new Set(settings.disabledExtensions);
        return settings.extensions.filter((p) => !disabled.has(p));
      }),
      forgetSkill: (name) =>
        Effect.sync(() => {
          settings = {
            ...settings,
            defaultSkills: settings.defaultSkills.filter((s) => s !== name),
            disabledSkills: settings.disabledSkills.filter((s) => s !== name),
          };
          flush();
          return settings;
        }),
      renameSkill: (oldName, newName) =>
        Effect.sync(() => {
          const swap = (list: string[]): string[] => {
            const next = list.map((s) => (s === oldName ? newName : s));
            return [...new Set(next)]; // collapse a dup if newName was already present
          };
          settings = {
            ...settings,
            defaultSkills: swap(settings.defaultSkills),
            disabledSkills: swap(settings.disabledSkills),
          };
          flush();
          return settings;
        }),
      setProjectRoot: (root, present) =>
        Effect.sync(() => {
          const next = new Set(settings.projectRoots);
          if (present) next.add(root);
          else next.delete(root);
          settings = { ...settings, projectRoots: [...next] };
          flush();
          return settings;
        }),
    } satisfies SettingsStoreHandle;
  });

// ---------------------------------------------------------------------------
// 3. Service tag (factory — stores are opened per data dir) + 4. Live layer
// ---------------------------------------------------------------------------

export interface PersistenceShape {
  /** Open the sessions index (sessions.json) under `dataDir`. */
  readonly openSessionIndex: (dataDir?: string) => Effect.Effect<SessionIndexHandle>;
  /** Open the projects index (projects.json) under `dataDir`. */
  readonly openProjectIndex: (dataDir?: string) => Effect.Effect<ProjectIndexHandle>;
  /** Open the app-settings store (app-settings.json) under `dataDir`. */
  readonly openSettingsStore: (dataDir?: string) => Effect.Effect<SettingsStoreHandle>;
}

/**
 * Persistence service (t3code's Services/ role): the leaf that opens the app's
 * JSON stores. A FACTORY (like SessionPushBuses) rather than one global handle,
 * since a store is bound to a data dir — servers under different data dirs (tests)
 * open their own.
 */
export class Persistence extends Context.Tag("agent-deck/server/services/Persistence")<
  Persistence,
  PersistenceShape
>() {}

export const PersistenceLive = Layer.succeed(Persistence, {
  openSessionIndex: (dataDir = defaultDataDir()) =>
    makeJsonArrayStoreHandle<SessionMeta>(dataDir, "sessions.json"),
  openProjectIndex: (dataDir = defaultDataDir()) =>
    makeJsonArrayStoreHandle<ProjectMeta>(dataDir, "projects.json"),
  openSettingsStore: (dataDir = defaultDataDir()) => makeSettingsStoreHandle(dataDir),
});
