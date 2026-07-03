import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import path from "node:path";
import envPaths from "env-paths";
import type { SessionMeta } from "@agent-deck/domain";

/**
 * App-data persistence. pi owns the canonical session files; we keep a light
 * index of sessions this app created (survives server restarts). Writes are
 * atomic (tmp + rename).
 */

export function defaultDataDir(): string {
  return envPaths("agent-deck-cross-plat", { suffix: "" }).data;
}

export class SessionIndex {
  private readonly file: string;
  private sessions: SessionMeta[] = [];

  constructor(dataDir: string = defaultDataDir()) {
    this.file = path.join(dataDir, "sessions.json");
    mkdirSync(dataDir, { recursive: true });
    try {
      const parsed: unknown = JSON.parse(readFileSync(this.file, "utf8"));
      if (Array.isArray(parsed)) this.sessions = parsed as SessionMeta[];
    } catch {
      // Missing or corrupt index — start fresh; pi still owns the real sessions.
    }
  }

  list(): SessionMeta[] {
    return this.sessions;
  }

  upsert(meta: SessionMeta): void {
    const index = this.sessions.findIndex((s) => s.id === meta.id);
    if (index === -1) this.sessions.push(meta);
    else this.sessions[index] = meta;
    this.flush();
  }

  private flush(): void {
    const tmp = `${this.file}.tmp`;
    writeFileSync(tmp, JSON.stringify(this.sessions, null, 2));
    renameSync(tmp, this.file);
  }
}
