import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import {
  clampMaxIterations,
  LOOP_STRUCTURES,
  LOOP_WRITE_TARGETS,
  type LoopDefinition,
  type LoopStructure,
  type LoopWriteTarget,
} from "@agent-deck/domain";
import { parseFrontmatter } from "@earendil-works/pi-coding-agent";
import YAML from "yaml";
import { piAgentHome, type ResourceRoots } from "./paths.ts";

/**
 * Loop-definition persistence (native LoopDefinitionStore): one file per loop
 * under ~/.pi/agent/loops as `<slug>.loop.md` — frontmatter for the config, the
 * markdown body for the goal — mirroring the agent catalog. This is the Bank
 * CRUD; the run engine is a later slice. Unknown frontmatter round-trips so a
 * native `.loop.md` (which carries more fields) survives an edit here.
 */

const LOOP_SUFFIX = ".loop.md";

export function loopsDir(roots: ResourceRoots): string {
  return path.join(piAgentHome(roots), "loops");
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}
function asStructure(value: unknown): LoopStructure {
  return LOOP_STRUCTURES.includes(value as LoopStructure)
    ? (value as LoopStructure)
    : "singleAgent";
}
function asWriteTarget(value: unknown): LoopWriteTarget {
  return LOOP_WRITE_TARGETS.includes(value as LoopWriteTarget)
    ? (value as LoopWriteTarget)
    : "artifactMarkdown";
}

/** A filesystem-safe slug for the loop's filename. */
export function loopSlug(name: string): string {
  const slug = name
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return slug || "loop";
}

export function parseLoopFile(filePath: string, content: string): LoopDefinition {
  const { frontmatter, body } = parseFrontmatter(content);
  const base = path.basename(filePath).replace(/\.loop\.md$/i, "");
  return {
    id: filePath,
    name: asString(frontmatter.name) ?? base,
    description: asString(frontmatter.description) ?? "",
    goal: body.trim(),
    structure: asStructure(frontmatter.structure),
    agentName: asString(frontmatter.agentName) || undefined,
    maxIterations: clampMaxIterations(Number(frontmatter.maxIterations)),
    validationCommand: asString(frontmatter.validationCommand) ?? "",
    writeTarget: asWriteTarget(frontmatter.writeTarget),
    source: "user",
    filePath,
  };
}

export function scanLoops(roots: ResourceRoots): LoopDefinition[] {
  const dir = loopsDir(roots);
  let entries: string[];
  try {
    entries = readdirSync(dir);
  } catch {
    return []; // no loops dir yet
  }
  const loops: LoopDefinition[] = [];
  for (const entry of entries) {
    if (!entry.toLowerCase().endsWith(LOOP_SUFFIX)) continue;
    const filePath = path.join(dir, entry);
    try {
      loops.push(parseLoopFile(filePath, readFileSync(filePath, "utf8")));
    } catch {
      // Skip a malformed file.
    }
  }
  return loops.sort((a, b) => a.name.localeCompare(b.name));
}

export interface LoopEdit {
  name: string;
  description?: string;
  goal?: string;
  structure?: LoopStructure;
  agentName?: string;
  maxIterations?: number;
  validationCommand?: string;
  writeTarget?: LoopWriteTarget;
}

const LOOP_FIELD_ORDER = [
  "name",
  "description",
  "structure",
  "agentName",
  "maxIterations",
  "validationCommand",
  "writeTarget",
] as const;

function serializeFrontmatter(record: Record<string, unknown>): string {
  const ordered: Record<string, unknown> = {};
  for (const key of LOOP_FIELD_ORDER) {
    if (record[key] !== undefined) ordered[key] = record[key];
  }
  for (const [key, value] of Object.entries(record)) {
    if (!(key in ordered) && value !== undefined) ordered[key] = value;
  }
  return YAML.stringify(ordered).trimEnd();
}

function loopFilePath(roots: ResourceRoots, name: string): string {
  const dir = loopsDir(roots);
  const filePath = path.join(dir, `${loopSlug(name)}${LOOP_SUFFIX}`);
  // Defense-in-depth: the resolved file must stay inside the loops dir.
  if (!path.resolve(filePath).startsWith(path.resolve(dir) + path.sep)) {
    throw new Error("refusing to write outside the loops catalog");
  }
  return filePath;
}

/** The on-disk file of the loop whose name matches, regardless of its filename. */
function loopPathByName(roots: ResourceRoots, name: string): string | undefined {
  return scanLoops(roots).find((loop) => loop.name === name)?.filePath;
}

/**
 * Create or update a loop by name. An UPDATE targets the loop's actual file
 * (found by name, so a native `.loop.md` whose filename doesn't match its slug
 * is edited in place, never orphaned). A CREATE writes `<slug>.loop.md` and
 * throws "loop_slug_conflict" if that slug is already taken by a different loop.
 * Unknown frontmatter round-trips.
 */
export function writeLoopFile(roots: ResourceRoots, edit: LoopEdit): string {
  const dir = loopsDir(roots);
  const existingPath = loopPathByName(roots, edit.name);
  const filePath = existingPath ?? loopFilePath(roots, edit.name);
  let frontmatter: Record<string, unknown> = {};
  let body = "";
  if (existingPath) {
    const existing = parseFrontmatter(readFileSync(filePath, "utf8"));
    frontmatter = { ...existing.frontmatter };
    body = existing.body.trim();
  } else if (existsSync(filePath)) {
    // The slug is occupied by a loop with a different name — refuse to clobber.
    throw new Error("loop_slug_conflict");
  }

  frontmatter.name = edit.name;
  if (edit.description !== undefined) frontmatter.description = edit.description;
  if (edit.structure !== undefined) frontmatter.structure = edit.structure;
  if (edit.agentName !== undefined) {
    if (edit.agentName) frontmatter.agentName = edit.agentName;
    else delete frontmatter.agentName;
  }
  if (edit.maxIterations !== undefined) {
    frontmatter.maxIterations = clampMaxIterations(edit.maxIterations);
  }
  if (edit.validationCommand !== undefined) {
    if (edit.validationCommand) frontmatter.validationCommand = edit.validationCommand;
    else delete frontmatter.validationCommand;
  }
  if (edit.writeTarget !== undefined) frontmatter.writeTarget = edit.writeTarget;
  if (edit.goal !== undefined) body = edit.goal.trim();

  mkdirSync(dir, { recursive: true });
  writeFileSync(filePath, `---\n${serializeFrontmatter(frontmatter)}\n---\n\n${body}\n`);
  return filePath;
}

/** Delete a loop by name (its actual file, not the re-derived slug). No-op if absent. */
export function deleteLoopFile(roots: ResourceRoots, name: string): void {
  const filePath = loopPathByName(roots, name) ?? loopFilePath(roots, name);
  rmSync(filePath, { force: true });
}

/**
 * Duplicate a loop as a new "Copy of <name>" (native duplicateUserDefinition),
 * de-duplicating the name if a copy already exists. Returns the new loop's name.
 * Throws "loop_not_found" if the source doesn't exist.
 */
export function duplicateLoop(roots: ResourceRoots, name: string): string {
  const loops = scanLoops(roots);
  const source = loops.find((loop) => loop.name === name);
  if (!source) throw new Error("loop_not_found");
  // De-dup by SLUG (the filename key), not name — otherwise a name-unique copy
  // could still collide on disk with a differently-named loop and throw.
  const existingSlugs = new Set(loops.map((loop) => loopSlug(loop.name)));
  let copyName = `Copy of ${name}`;
  for (let n = 2; existingSlugs.has(loopSlug(copyName)); n += 1)
    copyName = `Copy of ${name} (${n})`;
  writeLoopFile(roots, {
    name: copyName,
    description: source.description,
    goal: source.goal,
    structure: source.structure,
    agentName: source.agentName,
    maxIterations: source.maxIterations,
    validationCommand: source.validationCommand,
    writeTarget: source.writeTarget,
  });
  return copyName;
}
