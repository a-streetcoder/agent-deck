import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
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

const AGENT_FIELD_ORDER = [
  "name",
  "description",
  "whenToUse",
  "model",
  "thinking",
  "systemPromptMode",
  "tools",
  "skills",
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
  if (edit.tools !== undefined) {
    if (edit.tools.length > 0) frontmatter.tools = edit.tools.join(", ");
    else delete frontmatter.tools;
  }
  if (edit.skills !== undefined) {
    if (edit.skills.length > 0) frontmatter.skills = edit.skills.join(", ");
    else delete frontmatter.skills;
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
