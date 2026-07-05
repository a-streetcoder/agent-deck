import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import path from "node:path";
import envPaths from "env-paths";
import type { ProjectMeta, SessionMeta } from "@agent-deck/domain";

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
  /** Skills the user turned off: unassignable, excluded from --skill injection. */
  disabledSkills: string[];
}

/** App-level settings (app-settings.json), atomic writes like the indexes. */
export class SettingsStore {
  private readonly file: string;
  private settings: AppSettings = { defaultSkills: [], disabledSkills: [] };

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
          disabledSkills: Array.isArray(record.disabledSkills)
            ? record.disabledSkills.map(String)
            : [],
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

  setDisabledSkill(name: string, disabled: boolean): AppSettings {
    const next = new Set(this.settings.disabledSkills);
    if (disabled) next.add(name);
    else next.delete(name);
    // A disabled skill can't also be a default.
    const defaults = new Set(this.settings.defaultSkills);
    if (disabled) defaults.delete(name);
    this.settings = { defaultSkills: [...defaults], disabledSkills: [...next] };
    this.flush();
    return this.settings;
  }

  /** Drop a skill name from every list (used when a skill is deleted). */
  forgetSkill(name: string): AppSettings {
    this.settings = {
      defaultSkills: this.settings.defaultSkills.filter((s) => s !== name),
      disabledSkills: this.settings.disabledSkills.filter((s) => s !== name),
    };
    this.flush();
    return this.settings;
  }

  private flush(): void {
    const tmp = `${this.file}.tmp`;
    writeFileSync(tmp, JSON.stringify(this.settings, null, 2));
    renameSync(tmp, this.file);
  }
}
