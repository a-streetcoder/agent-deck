import {
  cpSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { parseFrontmatter } from "@earendil-works/pi-coding-agent";
import YAML from "yaml";
import type { AgentEdit } from "./overrides.ts";
import {
  agentCatalogDirs,
  promptCatalogDirs,
  skillCatalogDirs,
  type ResourceRoots,
} from "./paths.ts";

/**
 * File writers for global/project agents and skills. Existing files keep
 * their unknown frontmatter fields: we parse, merge only the edited keys,
 * and re-serialize. Builtins are handled by overrides.ts, never here.
 */

export type WritableScope = "global" | "project";

function agentDirFor(roots: ResourceRoots, scope: WritableScope): string {
  const dir = agentCatalogDirs(roots).find((d) => d.scope === scope && !d.legacy)?.dir;
  if (!dir) throw new Error(`no ${scope} agent directory (is a project selected?)`);
  return dir;
}

function skillDirFor(roots: ResourceRoots, scope: WritableScope): string {
  const dir = skillCatalogDirs(roots).find((d) => d.scope === scope)?.dir;
  if (!dir) throw new Error(`no ${scope} skill directory (is a project selected?)`);
  return dir;
}

/** Defense-in-depth: the resolved .md must stay inside the agent catalog. */
function agentFilePath(roots: ResourceRoots, scope: WritableScope, name: string): string {
  const dir = agentDirFor(roots, scope);
  const filePath = path.join(dir, `${name}.md`);
  if (!path.resolve(filePath).startsWith(path.resolve(dir) + path.sep)) {
    throw new Error("refusing to write outside the agent catalog");
  }
  return filePath;
}

function promptDirFor(roots: ResourceRoots, scope: WritableScope): string {
  const dir = promptCatalogDirs(roots).find((d) => d.scope === scope)?.dir;
  if (!dir) throw new Error(`no ${scope} prompt directory (is a project selected?)`);
  return dir;
}

/** Defense-in-depth: the resolved .md must stay inside the prompt catalog. */
function promptFilePath(roots: ResourceRoots, scope: WritableScope, name: string): string {
  const dir = promptDirFor(roots, scope);
  const filePath = path.join(dir, `${name}.md`);
  if (!path.resolve(filePath).startsWith(path.resolve(dir) + path.sep)) {
    throw new Error("refusing to write outside the prompt catalog");
  }
  return filePath;
}

/** Create or update a prompt-template .md file, preserving unknown frontmatter. */
export function writePromptFile(
  roots: ResourceRoots,
  scope: WritableScope,
  name: string,
  edit: { description?: string; body?: string },
): string {
  const filePath = promptFilePath(roots, scope, name);

  let frontmatter: Record<string, unknown> = {};
  let body = "";
  try {
    const existing = parseFrontmatter(readFileSync(filePath, "utf8"));
    frontmatter = { ...existing.frontmatter };
    body = existing.body.trim();
  } catch {
    // New prompt.
  }

  frontmatter.name = name;
  if (edit.description !== undefined) frontmatter.description = edit.description;
  if (edit.body !== undefined) body = edit.body.trim();

  mkdirSync(promptDirFor(roots, scope), { recursive: true });
  writeFileSync(filePath, `---\n${serializeFrontmatter(frontmatter)}\n---\n\n${body}\n`);
  return filePath;
}

/** Delete a global/project prompt-template .md file. */
export function deletePromptFile(roots: ResourceRoots, scope: WritableScope, name: string): void {
  rmSync(promptFilePath(roots, scope, name), { force: true });
}

/** True when two paths refer to the same on-disk file (same device + inode). */
function isSameFile(a: string, b: string): boolean {
  try {
    const sa = statSync(a);
    const sb = statSync(b);
    return sa.dev === sb.dev && sa.ino === sb.ino;
  } catch {
    return false;
  }
}

/**
 * Rename a prompt-template .md file within the same scope, preserving its body,
 * description, and any unknown frontmatter, and updating the `name` field to
 * match the new filename (pi exposes prompts as /prompt:<filename>). Throws
 * "prompt_not_found" if the source is missing and "prompt_exists" if the target
 * name is already taken — the caller maps these to 404 / 409.
 */
/**
 * Move a resource .md file within its scope dir, preserving the body and any
 * unknown frontmatter and setting `name` to the new filename. Handles a
 * case-only rename on case-insensitive filesystems (renameSync changes the
 * stored case, which a plain write wouldn't) and otherwise claims the target
 * with an exclusive create — which both rejects a real name clash AND closes
 * the check-then-write TOCTOU (a file appearing in the gap fails the write
 * instead of being clobbered). Throws `${kind}_not_found` / `${kind}_exists`.
 */
function renameMarkdownFile(
  from: string,
  to: string,
  dir: string,
  kind: "prompt" | "agent",
  newName: string,
): string {
  if (from === to) return to; // no-op: nothing to rename
  let parsed: { frontmatter: Record<string, unknown>; body: string };
  try {
    parsed = parseFrontmatter(readFileSync(from, "utf8"));
  } catch {
    throw new Error(`${kind}_not_found`);
  }
  const content = `---\n${serializeFrontmatter({ ...parsed.frontmatter, name: newName })}\n---\n\n${parsed.body.trim()}\n`;

  // A case-only rename (review→Review) is the one case where `to` can "exist"
  // yet actually BE `from` (same inode on a case-insensitive filesystem).
  if (from.toLowerCase() === to.toLowerCase() && existsSync(to) && isSameFile(from, to)) {
    renameSync(from, to);
    writeFileSync(to, content);
    return to;
  }

  mkdirSync(dir, { recursive: true });
  try {
    writeFileSync(to, content, { flag: "wx" });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "EEXIST") throw new Error(`${kind}_exists`);
    throw error;
  }
  rmSync(from, { force: true });
  return to;
}

export function renamePromptFile(
  roots: ResourceRoots,
  scope: WritableScope,
  name: string,
  newName: string,
): string {
  return renameMarkdownFile(
    promptFilePath(roots, scope, name),
    promptFilePath(roots, scope, newName),
    promptDirFor(roots, scope),
    "prompt",
    newName,
  );
}

const AGENT_FIELD_ORDER = [
  "name",
  "description",
  "whenToUse",
  "model",
  "fallbackModels",
  "thinking",
  "systemPromptMode",
  "tools",
  "skills",
  "mcpServers",
] as const;

function serializeFrontmatter(record: Record<string, unknown>): string {
  const ordered: Record<string, unknown> = {};
  for (const key of AGENT_FIELD_ORDER) {
    if (record[key] !== undefined) ordered[key] = record[key];
  }
  for (const [key, value] of Object.entries(record)) {
    if (!(key in ordered) && value !== undefined) ordered[key] = value;
  }
  return YAML.stringify(ordered).trimEnd();
}

/** Create or update an agent markdown file, preserving unknown frontmatter. */
export function writeAgentFile(
  roots: ResourceRoots,
  scope: WritableScope,
  name: string,
  edit: AgentEdit,
): string {
  const dir = agentDirFor(roots, scope);
  const filePath = path.join(dir, `${name}.md`);

  let frontmatter: Record<string, unknown> = {};
  let body = "";
  try {
    const existing = parseFrontmatter(readFileSync(filePath, "utf8"));
    frontmatter = { ...existing.frontmatter };
    body = existing.body.trim();
  } catch {
    // New file.
  }

  frontmatter.name = name;
  const setOrDelete = (key: string, value: string | undefined) => {
    if (value === undefined) return;
    if (value === "") delete frontmatter[key];
    else frontmatter[key] = value;
  };
  setOrDelete("description", edit.description);
  setOrDelete("whenToUse", edit.whenToUse);
  setOrDelete("model", edit.model);
  setOrDelete("thinking", edit.thinking);
  if (edit.systemPromptMode !== undefined) frontmatter.systemPromptMode = edit.systemPromptMode;
  if (edit.fallbackModels !== undefined) {
    if (edit.fallbackModels.length > 0) frontmatter.fallbackModels = edit.fallbackModels.join(", ");
    else delete frontmatter.fallbackModels;
  }
  if (edit.tools !== undefined) {
    if (edit.tools.length > 0) frontmatter.tools = edit.tools.join(", ");
    else delete frontmatter.tools;
  }
  if (edit.skills !== undefined) {
    if (edit.skills.length > 0) frontmatter.skills = edit.skills.join(", ");
    else delete frontmatter.skills;
  }
  if (edit.mcpServers !== undefined) {
    if (edit.mcpServers.length > 0) frontmatter.mcpServers = edit.mcpServers.join(", ");
    else delete frontmatter.mcpServers;
  }
  if (edit.body !== undefined) body = edit.body.trim();

  mkdirSync(dir, { recursive: true });
  writeFileSync(filePath, `---\n${serializeFrontmatter(frontmatter)}\n---\n\n${body}\n`);
  return filePath;
}

/** Create or update a skill's SKILL.md, preserving unknown frontmatter. */
export function writeSkillFile(
  roots: ResourceRoots,
  scope: WritableScope,
  name: string,
  edit: { description?: string; body?: string },
): string {
  const dir = path.join(skillDirFor(roots, scope), name);
  const filePath = path.join(dir, "SKILL.md");

  let frontmatter: Record<string, unknown> = {};
  let body = "";
  try {
    const existing = parseFrontmatter(readFileSync(filePath, "utf8"));
    frontmatter = { ...existing.frontmatter };
    body = existing.body.trim();
  } catch {
    // New skill.
  }

  frontmatter.name = name;
  if (edit.description !== undefined) frontmatter.description = edit.description;
  if (edit.body !== undefined) body = edit.body.trim();

  mkdirSync(dir, { recursive: true });
  writeFileSync(filePath, `---\n${YAML.stringify(frontmatter).trimEnd()}\n---\n\n${body}\n`);
  return filePath;
}

/** Delete a global/project agent's .md file. Builtins are never touched here. */
export function deleteAgentFile(roots: ResourceRoots, scope: WritableScope, name: string): void {
  const filePath = path.join(agentDirFor(roots, scope), `${name}.md`);
  rmSync(filePath, { force: true });
}

/**
 * Rename a global/project agent's .md file, preserving its body + frontmatter
 * and syncing the `name` field. Builtins can't be renamed (their name is the
 * override key). Throws "agent_not_found" / "agent_exists" (→ 404 / 409); the
 * caller is responsible for re-pointing any project defaults at the new name.
 */
export function renameAgentFile(
  roots: ResourceRoots,
  scope: WritableScope,
  name: string,
  newName: string,
): string {
  return renameMarkdownFile(
    agentFilePath(roots, scope, name),
    agentFilePath(roots, scope, newName),
    agentDirFor(roots, scope),
    "agent",
    newName,
  );
}

/** Set the `disabled` frontmatter flag on a global/project agent file. */
export function setAgentDisabledFile(
  roots: ResourceRoots,
  scope: WritableScope,
  name: string,
  disabled: boolean,
): void {
  const filePath = path.join(agentDirFor(roots, scope), `${name}.md`);
  const existing = parseFrontmatter(readFileSync(filePath, "utf8"));
  const frontmatter: Record<string, unknown> = { ...existing.frontmatter };
  if (disabled) frontmatter.disabled = true;
  else delete frontmatter.disabled;
  // A metadata-only toggle preserves the body verbatim (no re-trim).
  writeFileSync(filePath, `---\n${serializeFrontmatter(frontmatter)}\n---\n${existing.body}`);
}

/** Delete a global/project skill directory (its SKILL.md + contents). */
export function deleteSkillDir(roots: ResourceRoots, scope: WritableScope, name: string): void {
  const dir = path.join(skillDirFor(roots, scope), name);
  // Guard against traversal: the resolved dir must stay under the catalog.
  const catalog = skillDirFor(roots, scope);
  if (!path.resolve(dir).startsWith(path.resolve(catalog) + path.sep)) {
    throw new Error("refusing to delete outside the skill catalog");
  }
  rmSync(dir, { recursive: true, force: true });
  // Prune the catalog dir if it's now empty.
  try {
    if (readdirSync(catalog).length === 0) rmSync(catalog, { recursive: true, force: true });
  } catch {
    // Non-fatal.
  }
}

/** Defense-in-depth: the resolved skill dir must stay inside the catalog. */
function skillDirPath(roots: ResourceRoots, scope: WritableScope, name: string): string {
  const catalog = skillDirFor(roots, scope);
  const dir = path.join(catalog, name);
  if (!path.resolve(dir).startsWith(path.resolve(catalog) + path.sep)) {
    throw new Error("refusing to touch outside the skill catalog");
  }
  return dir;
}

/**
 * Rename a global/project skill DIRECTORY (a skill is a folder holding SKILL.md
 * plus any assets), preserving every file and syncing SKILL.md's `name` to the
 * new directory name. Throws "skill_not_found" / "skill_exists" (→ 404 / 409);
 * the caller re-points any project assignments.
 */
export function renameSkillDir(
  roots: ResourceRoots,
  scope: WritableScope,
  name: string,
  newName: string,
): string {
  const from = skillDirPath(roots, scope, name);
  const to = skillDirPath(roots, scope, newName);
  if (from === to) return to; // no-op: nothing to rename
  if (!existsSync(from)) throw new Error("skill_not_found");

  // A case-only rename (skill→Skill) resolves `to` onto `from` on a
  // case-insensitive filesystem (same inode) — not a real clash.
  const caseOnly =
    from.toLowerCase() === to.toLowerCase() && existsSync(to) && isSameFile(from, to);
  if (!caseOnly && existsSync(to)) throw new Error("skill_exists");
  try {
    renameSync(from, to);
  } catch (error) {
    // Backstop for a target that races into the gap after the existsSync check:
    // a non-empty dir throws ENOTEMPTY/EEXIST (POSIX) or EPERM (Windows). A real
    // skill dir is always non-empty (it holds SKILL.md), so a genuine clash
    // always lands here. The one residual race — an EMPTY dir appearing at `to`
    // on POSIX — is replaced silently, but loses nothing (it was empty).
    const code = (error as NodeJS.ErrnoException).code;
    if (code === "ENOTEMPTY" || code === "EEXIST" || code === "EPERM") {
      throw new Error("skill_exists");
    }
    throw error;
  }

  // Keep SKILL.md's name field in step with the directory name.
  const skillFile = path.join(to, "SKILL.md");
  try {
    const parsed = parseFrontmatter(readFileSync(skillFile, "utf8"));
    const frontmatter = { ...parsed.frontmatter, name: newName };
    writeFileSync(
      skillFile,
      `---\n${YAML.stringify(frontmatter).trimEnd()}\n---\n\n${parsed.body.trim()}\n`,
    );
  } catch {
    // No SKILL.md to update — the directory move is still the rename.
  }
  return to;
}

/**
 * Import a local .md file as a new global/project skill (native SkillImportSheet
 * Local tab): the skill name comes from the file's frontmatter `name` (else its
 * filename), and its SKILL.md is written into the catalog with the name synced.
 * Returns the imported name. Throws "not_a_markdown_file" (bad source),
 * "invalid_skill_name" (can't derive a valid name), or "skill_exists".
 */
/** The content after a leading `---\n…\n---\n` frontmatter block, VERBATIM
 *  (parseFrontmatter trims its body, losing e.g. a leading indented code block). */
function rawBodyAfterFrontmatter(content: string): string {
  const match = /^---\r?\n[\s\S]*?\r?\n---\r?\n?/.exec(content);
  return match ? content.slice(match[0].length) : content;
}

/** Recursively find directories that contain a SKILL.md (skipping .git / node_modules). */
function findSkillDirs(root: string): string[] {
  const found: string[] = [];
  const walk = (dir: string): void => {
    let entries: string[];
    try {
      entries = readdirSync(dir);
    } catch {
      return;
    }
    if (entries.includes("SKILL.md")) found.push(dir);
    for (const entry of entries) {
      if (entry === ".git" || entry === "node_modules") continue;
      const full = path.join(dir, entry);
      try {
        // lstat (not stat): a symlinked directory returns false for isDirectory,
        // so we never follow a symlink out of the clone or into a symlink cycle.
        if (lstatSync(full).isDirectory()) walk(full);
      } catch {
        // Unreadable entry — skip.
      }
    }
  };
  walk(root);
  return found;
}

export interface SkillImportResult {
  imported: string[];
  skipped: string[];
}

/**
 * Import every skill found in a cloned repo dir into the scope's skill catalog
 * (native SkillRepositorySync). Rule (native): a SKILL.md at the repo root means
 * the whole repo is ONE skill; otherwise every SKILL.md's parent dir is a skill.
 * Each skill's directory is copied whole (assets included) with the .git dir
 * excluded. Names come from SKILL.md frontmatter `name`, else the dir basename
 * (or `repoName` for the root case). Existing + invalid names are skipped.
 */
export function importSkillsFromClone(
  roots: ResourceRoots,
  scope: WritableScope,
  cloneDir: string,
  repoName: string,
): SkillImportResult {
  const skillDirs = existsSync(path.join(cloneDir, "SKILL.md"))
    ? [cloneDir] // root SKILL.md → the whole repo is a single skill
    : findSkillDirs(cloneDir);
  const catalog = skillDirFor(roots, scope);
  const imported: string[] = [];
  const skipped: string[] = [];
  for (const srcDir of skillDirs) {
    let name: string;
    try {
      const fm = parseFrontmatter(readFileSync(path.join(srcDir, "SKILL.md"), "utf8")).frontmatter;
      name =
        typeof fm.name === "string" && fm.name.trim()
          ? fm.name.trim()
          : srcDir === cloneDir
            ? repoName
            : path.basename(srcDir);
    } catch {
      name = srcDir === cloneDir ? repoName : path.basename(srcDir);
    }
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name)) {
      skipped.push(name);
      continue;
    }
    const dest = path.join(catalog, name);
    if (existsSync(dest)) {
      skipped.push(name);
      continue;
    }
    mkdirSync(catalog, { recursive: true });
    cpSync(srcDir, dest, { recursive: true, filter: (src) => path.basename(src) !== ".git" });
    imported.push(name);
  }
  return { imported, skipped };
}

export function importSkillFile(
  roots: ResourceRoots,
  scope: WritableScope,
  sourcePath: string,
): string {
  if (!sourcePath.endsWith(".md") || !existsSync(sourcePath) || !statSync(sourcePath).isFile()) {
    throw new Error("not_a_markdown_file");
  }
  const content = readFileSync(sourcePath, "utf8");
  const parsed = parseFrontmatter(content);
  const fromFrontmatter =
    typeof parsed.frontmatter.name === "string" ? parsed.frontmatter.name.trim() : "";
  const name = fromFrontmatter || path.basename(sourcePath, ".md");
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name)) throw new Error("invalid_skill_name");
  const dir = skillDirPath(roots, scope, name);
  if (existsSync(dir)) throw new Error("skill_exists");
  // Skills need a description to be discoverable — default one if the file lacks it.
  const description =
    typeof parsed.frontmatter.description === "string" && parsed.frontmatter.description.trim()
      ? parsed.frontmatter.description
      : "Imported skill";
  // Write directly (not via writeSkillFile) so the body is preserved VERBATIM —
  // its .trim() would strip a leading indented code block — and any other
  // frontmatter the source carried is kept. Only name/description are synced.
  const frontmatter = { ...parsed.frontmatter, name, description };
  const rawBody = rawBodyAfterFrontmatter(content);
  const body = rawBody.endsWith("\n") ? rawBody : `${rawBody}\n`;
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    path.join(dir, "SKILL.md"),
    `---\n${serializeFrontmatter(frontmatter)}\n---\n\n${body}`,
  );
  return name;
}
