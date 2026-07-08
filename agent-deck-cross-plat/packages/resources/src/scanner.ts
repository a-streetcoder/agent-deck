import { readdirSync, readFileSync, type Dirent } from "node:fs";
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
  extensionCatalogDirs,
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

/** A pi extension file discovered in a catalog dir (native PiExtensionCandidate). */
export interface DiscoveredExtension {
  name: string;
  path: string;
  scope: ResourceScope;
}

/** pi loads extensions written in TS or JS (any module flavor). */
const EXTENSION_FILE_RE = /\.(ts|mts|cts|js|mjs|cjs)$/i;

/**
 * Discover the user's own extension files in the standard pi locations (global
 * ~/.pi/agent/extensions + the project's .pi/extensions), so they appear in the
 * Extensions screen without being added by hand — mirroring how agents/skills
 * are discovered. App-generated bridge extensions are written elsewhere and are
 * never scanned here, so a user can't see or disable them. A project entry wins
 * over a global one at the same path (there is none — paths are absolute), and
 * duplicates are de-duped by absolute path.
 */
export function scanExtensions(roots: ResourceRoots): DiscoveredExtension[] {
  const found: DiscoveredExtension[] = [];
  const seen = new Set<string>();
  for (const { dir, scope } of extensionCatalogDirs(roots)) {
    let entries: Dirent[];
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      continue; // the dir doesn't exist — nothing to discover there
    }
    for (const entry of entries) {
      if (!entry.isFile() || !EXTENSION_FILE_RE.test(entry.name)) continue;
      const full = path.join(dir, entry.name);
      if (seen.has(full)) continue;
      seen.add(full);
      found.push({ name: entry.name, path: full, scope });
    }
  }
  return found;
}
