import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import path from "node:path";
import envPaths from "env-paths";
import {
  THINKING_LEVELS,
  type ProjectMeta,
  type SessionMeta,
  type ThinkingLevel,
} from "@agent-deck/domain";

/**
 * App-data persistence. pi owns the canonical session files; we keep light
 * JSON indexes (sessions, projects) that survive server restarts. Writes are
 * atomic (tmp + rename).
 */

export function defaultDataDir(): string {
  return envPaths("agent-deck-cross-plat", { suffix: "" }).data;
}

class JsonArrayStore<T extends { id: string }> {
  private readonly file: string;
  private items: T[] = [];

  constructor(dataDir: string, fileName: string) {
    this.file = path.join(dataDir, fileName);
    mkdirSync(dataDir, { recursive: true });
    try {
      const parsed: unknown = JSON.parse(readFileSync(this.file, "utf8"));
      if (Array.isArray(parsed)) this.items = parsed as T[];
    } catch {
      // Missing or corrupt index — start fresh.
    }
  }

  list(): T[] {
    return this.items;
  }

  find(predicate: (item: T) => boolean): T | undefined {
    return this.items.find(predicate);
  }

  upsert(item: T): void {
    const index = this.items.findIndex((existing) => existing.id === item.id);
    if (index === -1) this.items.push(item);
    else this.items[index] = item;
    this.flush();
  }

  remove(id: string): boolean {
    const index = this.items.findIndex((existing) => existing.id === id);
    if (index === -1) return false;
    this.items.splice(index, 1);
    this.flush();
    return true;
  }

  private flush(): void {
    const tmp = `${this.file}.tmp`;
    writeFileSync(tmp, JSON.stringify(this.items, null, 2));
    renameSync(tmp, this.file);
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
   * Onboarding-preferences (native OnboardingPreferencesView). `defaultModel` /
   * `defaultThinking` seed every NEW parent ("All Projects" / Pi Agent) session's
   * launch when the request doesn't override them; `autoTitle` gates the
   * title-helper launch. `worktreeIsolation` / `gitAutomation` are persisted
   * preferences reserved for the features that will read them — the port has no
   * session-worktree-isolation or git-automation runtime yet, so they are stored
   * (surfaced in the UI) but not acted on.
   */
  autoTitle: boolean;
  worktreeIsolation: boolean;
  gitAutomation: boolean;
  defaultModel: string | null;
  defaultThinking: ThinkingLevel | null;
}

/** App-level settings (app-settings.json), atomic writes like the indexes. */
export class SettingsStore {
  private readonly file: string;
  private settings: AppSettings = {
    defaultSkills: [],
    defaultPromptTemplates: [],
    disabledSkills: [],
    projectRoots: [],
    extensions: [],
    disabledExtensions: [],
    disabledModels: [],
    autoTitle: true, // native default: sessions are auto-titled by the helper
    worktreeIsolation: false,
    gitAutomation: false,
    defaultModel: null,
    defaultThinking: null,
  };

  constructor(dataDir: string = defaultDataDir()) {
    this.file = path.join(dataDir, "app-settings.json");
    mkdirSync(dataDir, { recursive: true });
    try {
      const parsed: unknown = JSON.parse(readFileSync(this.file, "utf8"));
      if (typeof parsed === "object" && parsed !== null) {
        const record = parsed as Partial<AppSettings>;
        this.settings = {
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
          gitAutomation: typeof record.gitAutomation === "boolean" ? record.gitAutomation : false,
          defaultModel: typeof record.defaultModel === "string" ? record.defaultModel : null,
          defaultThinking:
            typeof record.defaultThinking === "string" &&
            (THINKING_LEVELS as readonly string[]).includes(record.defaultThinking)
              ? (record.defaultThinking as ThinkingLevel)
              : null,
        };
      }
    } catch {
      // Missing or corrupt — defaults apply.
    }
  }

  get(): AppSettings {
    return this.settings;
  }

  update(patch: Partial<AppSettings>): AppSettings {
    this.settings = { ...this.settings, ...patch };
    this.flush();
    return this.settings;
  }

  /**
   * Atomic membership ops — computed against CURRENT state so concurrent
   * clients can't clobber each other with stale whole-array replacements.
   */
  setDefaultSkill(name: string, enabled: boolean): AppSettings {
    const next = new Set(this.settings.defaultSkills);
    if (enabled) next.add(name);
    else next.delete(name);
    this.settings = { ...this.settings, defaultSkills: [...next] };
    this.flush();
    return this.settings;
  }

  setDefaultPromptTemplate(name: string, enabled: boolean): AppSettings {
    const next = new Set(this.settings.defaultPromptTemplates);
    if (enabled) next.add(name);
    else next.delete(name);
    this.settings = { ...this.settings, defaultPromptTemplates: [...next] };
    this.flush();
    return this.settings;
  }

  /** Rename/delete upkeep: rewrite (or drop, with newName=null) a default entry. */
  renameDefaultPromptTemplate(oldName: string, newName: string | null): AppSettings {
    const next = new Set(this.settings.defaultPromptTemplates);
    if (!next.has(oldName)) return this.settings;
    next.delete(oldName);
    if (newName !== null) next.add(newName);
    this.settings = { ...this.settings, defaultPromptTemplates: [...next] };
    this.flush();
    return this.settings;
  }

  setDisabledSkill(name: string, disabled: boolean): AppSettings {
    const next = new Set(this.settings.disabledSkills);
    if (disabled) next.add(name);
    else next.delete(name);
    // A disabled skill can't also be a default.
    const defaults = new Set(this.settings.defaultSkills);
    if (disabled) defaults.delete(name);
    this.settings = {
      ...this.settings,
      defaultSkills: [...defaults],
      disabledSkills: [...next],
    };
    this.flush();
    return this.settings;
  }

  /** Add an extension path (idempotent), enabled by default. */
  addExtension(extPath: string): AppSettings {
    const next = new Set(this.settings.extensions);
    next.add(extPath);
    this.settings = { ...this.settings, extensions: [...next] };
    this.flush();
    return this.settings;
  }

  /** Remove an extension path from both lists entirely. */
  removeExtension(extPath: string): AppSettings {
    this.settings = {
      ...this.settings,
      extensions: this.settings.extensions.filter((p) => p !== extPath),
      disabledExtensions: this.settings.disabledExtensions.filter((p) => p !== extPath),
    };
    this.flush();
    return this.settings;
  }

  setExtensionDisabled(extPath: string, disabled: boolean): AppSettings {
    const next = new Set(this.settings.disabledExtensions);
    if (disabled) next.add(extPath);
    else next.delete(extPath);
    this.settings = { ...this.settings, disabledExtensions: [...next] };
    this.flush();
    return this.settings;
  }

  /** Hide/show a model in the picker, by its "<provider>:<id>" key. */
  setModelDisabled(key: string, disabled: boolean): AppSettings {
    const next = new Set(this.settings.disabledModels);
    if (disabled) next.add(key);
    else next.delete(key);
    this.settings = { ...this.settings, disabledModels: [...next] };
    this.flush();
    return this.settings;
  }

  /** Enabled extension paths — merged into every session launch. */
  enabledExtensions(): string[] {
    const disabled = new Set(this.settings.disabledExtensions);
    return this.settings.extensions.filter((p) => !disabled.has(p));
  }

  /** Drop a skill name from every list (used when a skill is deleted). */
  forgetSkill(name: string): AppSettings {
    this.settings = {
      ...this.settings,
      defaultSkills: this.settings.defaultSkills.filter((s) => s !== name),
      disabledSkills: this.settings.disabledSkills.filter((s) => s !== name),
    };
    this.flush();
    return this.settings;
  }

  /** Re-point a renamed skill in every app-level list (default + disabled). */
  renameSkill(oldName: string, newName: string): AppSettings {
    const swap = (list: string[]): string[] => {
      const next = list.map((s) => (s === oldName ? newName : s));
      return [...new Set(next)]; // collapse a dup if newName was already present
    };
    this.settings = {
      ...this.settings,
      defaultSkills: swap(this.settings.defaultSkills),
      disabledSkills: swap(this.settings.disabledSkills),
    };
    this.flush();
    return this.settings;
  }

  /** Add or remove a discovery root (atomic membership op). */
  setProjectRoot(root: string, present: boolean): AppSettings {
    const next = new Set(this.settings.projectRoots);
    if (present) next.add(root);
    else next.delete(root);
    this.settings = { ...this.settings, projectRoots: [...next] };
    this.flush();
    return this.settings;
  }

  private flush(): void {
    const tmp = `${this.file}.tmp`;
    writeFileSync(tmp, JSON.stringify(this.settings, null, 2));
    renameSync(tmp, this.file);
  }
}
