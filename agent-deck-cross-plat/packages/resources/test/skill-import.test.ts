import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { skillCatalogDirs } from "../src/paths.ts";
import { scanSkills } from "../src/scanner.ts";
import { importSkillFile } from "../src/writer.ts";

/**
 * Skill import (native SkillImportSheet Local tab, 7.3): copy a local .md into
 * the catalog as a new skill, taking its name from frontmatter (else filename)
 * and syncing SKILL.md.
 */

function home(): string {
  return mkdtempSync(path.join(tmpdir(), "skill-import-home-"));
}
function srcFile(name: string, content: string): string {
  const p = path.join(mkdtempSync(path.join(tmpdir(), "skill-src-")), name);
  writeFileSync(p, content);
  return p;
}
function globalSkillDir(roots: { home: string }, name: string): string {
  return path.join(skillCatalogDirs(roots).find((d) => d.scope === "global")!.dir, name);
}

describe("importSkillFile", () => {
  it("imports a .md, taking the name from frontmatter and writing SKILL.md", () => {
    const roots = { home: home() };
    const source = srcFile(
      "whatever.md",
      "---\nname: linter\ndescription: Lint the code\n---\n\nRun eslint.",
    );

    const name = importSkillFile(roots, "global", source);
    expect(name).toBe("linter");

    const skills = scanSkills(roots);
    expect(skills.map((s) => s.name)).toEqual(["linter"]);
    expect(skills[0]!.description).toBe("Lint the code");
    expect(skills[0]!.body).toBe("Run eslint.");
    expect(readFileSync(path.join(globalSkillDir(roots, "linter"), "SKILL.md"), "utf8")).toContain(
      "name: linter",
    );
  });

  it("falls back to the filename and a default description when frontmatter is sparse", () => {
    const roots = { home: home() };
    const source = srcFile("format-code.md", "Just a body, no frontmatter.\n");
    const name = importSkillFile(roots, "global", source);
    expect(name).toBe("format-code");
    expect(scanSkills(roots)[0]!.description).toBe("Imported skill");
  });

  it("throws skill_exists when the name is already taken", () => {
    const roots = { home: home() };
    const source = srcFile("dup.md", "---\nname: dup\ndescription: d\n---\n\nb");
    importSkillFile(roots, "global", source);
    expect(() => importSkillFile(roots, "global", source)).toThrow("skill_exists");
  });

  it("throws not_a_markdown_file for a missing or non-.md source", () => {
    const roots = { home: home() };
    expect(() => importSkillFile(roots, "global", "/no/such/file.md")).toThrow(
      "not_a_markdown_file",
    );
    const txt = srcFile("notes.txt", "hello");
    expect(() => importSkillFile(roots, "global", txt)).toThrow("not_a_markdown_file");
  });

  it("preserves the body VERBATIM (leading indentation) and other frontmatter", () => {
    const roots = { home: home() };
    // A body that opens with an indented code block, plus an extra frontmatter key.
    const source = srcFile(
      "verb.md",
      "---\nname: verbatim\ndescription: d\ndisableModelInvocation: true\n---\n    indented code\nplain line\n",
    );
    importSkillFile(roots, "global", source);
    const written = readFileSync(path.join(globalSkillDir(roots, "verbatim"), "SKILL.md"), "utf8");
    // The leading 4-space indent survives (writeSkillFile's .trim() would have eaten it).
    expect(written).toContain("\n    indented code\n");
    // A non-name/description frontmatter field is carried over.
    expect(written).toContain("disableModelInvocation: true");
  });

  it("throws invalid_skill_name when no valid name can be derived", () => {
    const roots = { home: home() };
    // Frontmatter name with illegal chars and a filename that also can't be a name.
    const source = srcFile("bad name!.md", "---\nname: bad/name\ndescription: d\n---\n\nb");
    expect(() => importSkillFile(roots, "global", source)).toThrow("invalid_skill_name");
    expect(existsSync(globalSkillDir(roots, "bad/name"))).toBe(false);
  });
});
