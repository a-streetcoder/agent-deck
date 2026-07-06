import { statSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { ResourceScope } from "@agent-deck/domain";

function isFile(filePath: string): boolean {
  try {
    return statSync(filePath).isFile();
  } catch {
    return false;
  }
}

/**
 * Every location scanned for resources, per
 * agent-deck-documentation/reference/file-locations.md. `home` is injectable
 * for hermetic tests.
 */

export interface ResourceRoots {
  home: string;
  /** Current project root, when a project is selected. */
  projectPath?: string;
}

export function defaultRoots(projectPath?: string): ResourceRoots {
  return { home: homedir(), projectPath };
}

export function piAgentHome(roots: ResourceRoots): string {
  return path.join(roots.home, ".pi", "agent");
}

/**
 * The active APPEND_SYSTEM.md pi would auto-discover, with pi's precedence:
 * project `<project>/.pi/APPEND_SYSTEM.md`, else global
 * `~/.pi/agent/APPEND_SYSTEM.md` (agent-deck-system-prompt-logic.md). Because
 * any explicit --append-system-prompt suppresses pi's automatic discovery, the
 * launch flow must re-add this path ahead of Agent Deck's own appends so the
 * file is still honored. Not ancestor-walked. Returns undefined if neither
 * file exists.
 */
export function appendSystemPromptPath(roots: ResourceRoots): string | undefined {
  const candidates = [
    roots.projectPath ? path.join(roots.projectPath, ".pi", "APPEND_SYSTEM.md") : undefined,
    path.join(piAgentHome(roots), "APPEND_SYSTEM.md"),
  ];
  for (const candidate of candidates) {
    if (candidate && isFile(candidate)) return candidate;
  }
  return undefined;
}

export const BUILTIN_AGENTS_DIR = fileURLToPath(new URL("../builtin-agents", import.meta.url));

export interface AgentCatalogDir {
  dir: string;
  scope: ResourceScope;
  /** Legacy locations are scanned but never watched or created. */
  legacy?: boolean;
}

export function agentCatalogDirs(roots: ResourceRoots): AgentCatalogDir[] {
  const dirs: AgentCatalogDir[] = [
    { dir: BUILTIN_AGENTS_DIR, scope: "builtin" },
    { dir: path.join(piAgentHome(roots), "agents"), scope: "global" },
    { dir: path.join(roots.home, ".agents"), scope: "global", legacy: true },
    { dir: path.join(piAgentHome(roots), "agent-library", "agents"), scope: "library" },
  ];
  if (roots.projectPath) {
    dirs.push({ dir: path.join(roots.projectPath, ".pi", "agents"), scope: "project" });
    dirs.push({ dir: path.join(roots.projectPath, ".agents"), scope: "project", legacy: true });
  }
  return dirs;
}

export interface SkillCatalogDir {
  dir: string;
  scope: ResourceScope;
}

export function skillCatalogDirs(roots: ResourceRoots): SkillCatalogDir[] {
  const dirs: SkillCatalogDir[] = [
    { dir: path.join(piAgentHome(roots), "skills"), scope: "global" },
  ];
  if (roots.projectPath) {
    dirs.push({ dir: path.join(roots.projectPath, ".pi", "skills"), scope: "project" });
  }
  return dirs;
}

export interface PromptCatalogDir {
  dir: string;
  scope: ResourceScope;
}

/** Prompt-template catalog dirs — single .md files, pi's `/prompt:<name>`. */
export function promptCatalogDirs(roots: ResourceRoots): PromptCatalogDir[] {
  const dirs: PromptCatalogDir[] = [
    { dir: path.join(piAgentHome(roots), "prompts"), scope: "global" },
  ];
  if (roots.projectPath) {
    dirs.push({ dir: path.join(roots.projectPath, ".pi", "prompts"), scope: "project" });
  }
  return dirs;
}

/**
 * Directories the file watcher observes. Builtins never change and legacy
 * locations are excluded so they are never auto-created in user projects.
 */
export function watchDirs(roots: ResourceRoots): string[] {
  return [
    ...agentCatalogDirs(roots)
      .filter((d) => d.scope !== "builtin" && !d.legacy)
      .map((d) => d.dir),
    ...skillCatalogDirs(roots).map((d) => d.dir),
    ...promptCatalogDirs(roots).map((d) => d.dir),
  ];
}

/** The project-scoped watch dirs alone — for FSWatcher.add() when a project registers. */
export function projectWatchDirs(projectPath: string): string[] {
  return [
    path.join(projectPath, ".pi", "agents"),
    path.join(projectPath, ".pi", "skills"),
    path.join(projectPath, ".pi", "prompts"),
  ];
}
