import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import type { ProjectType } from "@agent-deck/domain";

/**
 * Project discovery, mirroring the native ProjectDiscovery + ProjectType:
 * scan a configured root folder one level deep, treat a subdirectory as a
 * project when it has .git / package.json / an Xcode project, and detect its
 * type from marker files. Read-only; never writes.
 */

function has(dir: string, file: string): boolean {
  return existsSync(path.join(dir, file));
}

function hasAny(dir: string, files: string[]): boolean {
  return files.some((file) => has(dir, file));
}

function hasXcodeProject(dir: string): boolean {
  try {
    return readdirSync(dir).some((e) => e.endsWith(".xcodeproj") || e.endsWith(".xcworkspace"));
  } catch {
    return false;
  }
}

/** package.json dependency+devDependency names, or empty on absence/parse error. */
function packageDeps(dir: string): Set<string> {
  try {
    const pkg = JSON.parse(readFileSync(path.join(dir, "package.json"), "utf8")) as {
      dependencies?: Record<string, string>;
      devDependencies?: Record<string, string>;
    };
    return new Set([
      ...Object.keys(pkg.dependencies ?? {}),
      ...Object.keys(pkg.devDependencies ?? {}),
    ]);
  } catch {
    return new Set();
  }
}

/** Detect a project's type from marker files (native ProjectType order). */
export function detectProjectType(dir: string): ProjectType {
  if (hasXcodeProject(dir)) return "xcode";
  if (has(dir, "tauri.conf.json") || has(dir, path.join("src-tauri", "tauri.conf.json"))) {
    return "tauri";
  }
  if (has(dir, "Package.swift")) return "swift";
  if (has(dir, "go.mod")) return "go";
  if (has(dir, "Cargo.toml")) return "rust";
  if (hasAny(dir, ["pyproject.toml", "requirements.txt", "manage.py", "setup.py", "Pipfile"])) {
    return "python";
  }
  if (hasAny(dir, ["Gemfile", "Rakefile", ".ruby-version"])) return "ruby";

  // JS/TS ecosystem: meta-frameworks first, then libraries, then bare node.
  if (hasAny(dir, ["nuxt.config.js", "nuxt.config.ts", "nuxt.config.mjs"])) return "nuxt";
  if (hasAny(dir, ["astro.config.mjs", "astro.config.js", "astro.config.ts"])) return "astro";
  if (hasAny(dir, ["svelte.config.js", "svelte.config.mjs"])) return "sveltekit";
  if (has(dir, "angular.json")) return "angular";
  if (hasAny(dir, ["next.config.js", "next.config.mjs", "next.config.ts"])) return "nextjs";
  if (has(dir, "package.json")) {
    const deps = packageDeps(dir);
    if (deps.has("@tauri-apps/api")) return "tauri";
    if (deps.has("electron")) return "electron";
    if (deps.has("next")) return "nextjs";
    if (deps.has("nuxt")) return "nuxt";
    if (deps.has("astro")) return "astro";
    if (deps.has("@sveltejs/kit")) return "sveltekit";
    if (deps.has("@angular/core")) return "angular";
    if (deps.has("vue")) return "vue";
    if (deps.has("react")) return "react";
    return "node";
  }
  if (has(dir, ".git")) return "git";
  return "unknown";
}

function isProjectDir(dir: string): boolean {
  return has(dir, ".git") || has(dir, "package.json") || hasXcodeProject(dir);
}

export interface DiscoveryCandidate {
  path: string;
  name: string;
  type: ProjectType;
}

/**
 * Scan a root folder one level deep and return the project subdirectories.
 * The root itself is included if it is a project.
 */
export function discoverProjectsInRoot(root: string): DiscoveryCandidate[] {
  const candidates: DiscoveryCandidate[] = [];
  const resolved = path.resolve(root);
  let rootIsProject = false;
  try {
    if (!statSync(resolved).isDirectory()) return [];
    rootIsProject = isProjectDir(resolved);
  } catch {
    return [];
  }
  if (rootIsProject) {
    candidates.push({
      path: resolved,
      name: path.basename(resolved),
      type: detectProjectType(resolved),
    });
  }
  let entries: string[];
  try {
    entries = readdirSync(resolved);
  } catch {
    return candidates;
  }
  for (const entry of entries) {
    if (entry.startsWith(".")) continue;
    const child = path.join(resolved, entry);
    try {
      if (!statSync(child).isDirectory() || !isProjectDir(child)) continue;
    } catch {
      continue;
    }
    candidates.push({ path: child, name: entry, type: detectProjectType(child) });
  }
  return candidates;
}

/** Discover across several roots, de-duplicated by resolved path. */
export function discoverProjects(roots: string[]): DiscoveryCandidate[] {
  const byPath = new Map<string, DiscoveryCandidate>();
  for (const root of roots) {
    for (const candidate of discoverProjectsInRoot(root)) {
      byPath.set(candidate.path, candidate);
    }
  }
  return [...byPath.values()].sort((a, b) => a.name.localeCompare(b.name));
}
