import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { parseFrontmatter } from "@earendil-works/pi-coding-agent";
import YAML from "yaml";
import type { AgentEdit } from "./overrides.ts";
import { agentCatalogDirs, skillCatalogDirs, type ResourceRoots } from "./paths.ts";

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
