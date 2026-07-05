import { existsSync, lstatSync, readdirSync, readFileSync, realpathSync, statSync } from "node:fs";
import path from "node:path";
import type { ProjectType } from "@agent-deck/domain";

/** Cap the per-root fan-out so a giant folder can't stall the event loop. */
const MAX_ENTRIES_PER_ROOT = 2000;
/** Skip package.json files larger than this when detecting type. */
const MAX_PACKAGE_JSON_BYTES = 512 * 1024;

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

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** package.json dependency+devDependency names, or empty on absence/parse error. */
function packageDeps(dir: string): Set<string> {
  try {
    const file = path.join(dir, "package.json");
    if (statSync(file).size > MAX_PACKAGE_JSON_BYTES) return new Set(); // don't parse huge files
    const pkg: unknown = JSON.parse(readFileSync(file, "utf8"));
    if (!isPlainObject(pkg)) return new Set();
    const deps = isPlainObject(pkg.dependencies) ? Object.keys(pkg.dependencies) : [];
    const dev = isPlainObject(pkg.devDependencies) ? Object.keys(pkg.devDependencies) : [];
    return new Set([...deps, ...dev]);
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
    entries = readdirSync(resolved).slice(0, MAX_ENTRIES_PER_ROOT);
  } catch {
    return candidates;
  }
  for (const entry of entries) {
    if (entry.startsWith(".")) continue;
    const child = path.join(resolved, entry);
    try {
      // lstat (not stat): a symlinked child is skipped so discovery can't
      // follow a link out of the configured root into slow/mounted/private
      // locations.
      if (!lstatSync(child).isDirectory() || !isProjectDir(child)) continue;
    } catch {
      continue;
    }
    candidates.push({ path: child, name: entry, type: detectProjectType(child) });
  }
  return candidates;
}

/** Canonicalize a path for identity comparison, tolerating missing targets. */
function canonical(p: string): string {
  try {
    return realpathSync.native(p);
  } catch {
    return path.resolve(p);
  }
}

/** Discover across several roots, de-duplicated by canonical (realpath) path. */
export function discoverProjects(roots: string[]): DiscoveryCandidate[] {
  const byPath = new Map<string, DiscoveryCandidate>();
  for (const root of roots) {
    for (const candidate of discoverProjectsInRoot(root)) {
      byPath.set(canonical(candidate.path), candidate);
    }
  }
  return [...byPath.values()].sort((a, b) => a.name.localeCompare(b.name));
}
