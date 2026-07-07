import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import {
  applyShadowing,
  type AgentInfo,
  type PromptInfo,
  type ResourceScope,
  type SkillInfo,
} from "@agent-deck/domain";
import { loadSkillsFromDir, parseFrontmatter } from "@earendil-works/pi-coding-agent";
import { applyAgentOverride, readAgentOverrides } from "./overrides.ts";
import {
  agentCatalogDirs,
  promptCatalogDirs,
  skillCatalogDirs,
  type ResourceRoots,
} from "./paths.ts";

/**
 * Filesystem scanners for agents and skills. Agent frontmatter follows
 * agent-deck-documentation/reference/agent-frontmatter.md; skill discovery
 * reuses pi's own loader so the rules match pi exactly.
 */

/** Frontmatter list fields arrive as YAML arrays OR comma-separated strings. */
function asList(value: unknown): string[] | undefined {
  if (Array.isArray(value)) {
    return value.map((item) => String(item).trim()).filter(Boolean);
  }
  if (typeof value === "string") {
    const items = value
      .split(",")
      .map((item) => item.trim())
      .filter(Boolean);
    return items.length > 0 ? items : undefined;
  }
  return undefined;
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

export function parseAgentFile(
  filePath: string,
  content: string,
  scope: ResourceScope,
): Omit<AgentInfo, "shadowed" | "replacesBuiltin"> {
  const { frontmatter, body } = parseFrontmatter(content);
  const mode = asString(frontmatter.systemPromptMode);
  return {
    name: asString(frontmatter.name) ?? path.basename(filePath, ".md"),
    description: asString(frontmatter.description),
    whenToUse: asString(frontmatter.whenToUse),
    model: asString(frontmatter.model),
    fallbackModels: asList(frontmatter.fallbackModels),
    thinking: asString(frontmatter.thinking),
    systemPromptMode: mode === "append" ? "append" : "replace",
    tools: asList(frontmatter.tools),
    skills: asList(frontmatter.skills),
    extensions: asList(frontmatter.extensions),
    mcpServers: asList(frontmatter.mcpServers),
    scope,
    filePath,
    body: body.trim(),
    disabled: frontmatter.disabled === true,
  };
}

export function scanAgents(roots: ResourceRoots): AgentInfo[] {
  const overrides = readAgentOverrides(roots);
  const raw: Omit<AgentInfo, "shadowed" | "replacesBuiltin">[] = [];
  for (const { dir, scope } of agentCatalogDirs(roots)) {
    let entries: string[];
    try {
      entries = readdirSync(dir);
    } catch {
      continue; // catalog dir doesn't exist
    }
    for (const entry of entries) {
      if (!entry.endsWith(".md")) continue;
      const filePath = path.join(dir, entry);
      try {
        let agent = parseAgentFile(filePath, readFileSync(filePath, "utf8"), scope);
        // Builtin edits live as diff-shaped overrides — the file is pristine.
        const override = scope === "builtin" ? overrides[agent.name] : undefined;
        if (override) agent = applyAgentOverride(agent, override);
        raw.push(agent);
      } catch {
        // Unreadable/malformed file — skip; a diagnostics channel comes later.
      }
    }
  }
  return applyShadowing(raw);
}

/**
 * Prompt templates: single .md files, `/prompt:<name>` in pi. Returns EVERY
 * scope's entry (no dedup) so a management UI can edit/delete both a global
 * prompt and a same-name project one — pi resolves precedence itself at load.
 */
export function scanPrompts(roots: ResourceRoots): PromptInfo[] {
  const prompts: PromptInfo[] = [];
  for (const { dir, scope } of promptCatalogDirs(roots)) {
    let entries: string[];
    try {
      entries = readdirSync(dir);
    } catch {
      continue;
    }
    for (const entry of entries) {
      if (!entry.endsWith(".md")) continue;
      const filePath = path.join(dir, entry);
      try {
        const { frontmatter, body } = parseFrontmatter(readFileSync(filePath, "utf8"));
        // A prompt's identity IS its file basename: pi registers the command
        // under the basename (expandPromptTemplate matches `/<basename>`) and
        // IGNORES any frontmatter `name`. So `name` (which edit/rename/delete and
        // the writer key off, as `${name}.md`) must be the basename too — trusting
        // a divergent frontmatter `name` would target the wrong file.
        const basename = path.basename(entry, ".md");
        prompts.push({
          name: basename,
          description: asString(frontmatter.description),
          scope,
          filePath,
          body: body.trim(),
          invocation: `/${basename}`,
          argumentHint: asString(frontmatter["argument-hint"]),
        });
      } catch {
        // Unreadable/malformed — skip.
      }
    }
  }
  return prompts.sort((a, b) => a.name.localeCompare(b.name) || a.scope.localeCompare(b.scope));
}

export function scanSkills(roots: ResourceRoots): SkillInfo[] {
  const skills: SkillInfo[] = [];
  for (const { dir, scope } of skillCatalogDirs(roots)) {
    const result = loadSkillsFromDir({ dir, source: scope });
    for (const skill of result.skills) {
      let body = "";
      try {
        body = parseFrontmatter(readFileSync(skill.filePath, "utf8")).body.trim();
      } catch {
        // Unreadable — leave the body empty.
      }
      skills.push({
        name: skill.name,
        description: skill.description,
        scope,
        filePath: skill.filePath,
        baseDir: skill.baseDir,
        disableModelInvocation: skill.disableModelInvocation,
        body,
      });
    }
  }
  return skills;
}
