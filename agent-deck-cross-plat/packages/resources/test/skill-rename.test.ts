import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { skillCatalogDirs } from "../src/paths.ts";
import { scanSkills } from "../src/scanner.ts";
import { renameSkillDir, writeSkillFile } from "../src/writer.ts";

/**
 * Skill rename (native RenameResourceSheet): a skill is a DIRECTORY holding
 * SKILL.md plus any assets, so rename moves the whole folder, preserving its
 * files and syncing SKILL.md's `name`.
 */

function home(): string {
  return mkdtempSync(path.join(tmpdir(), "skill-rename-home-"));
}

function globalSkillDir(roots: { home: string }, name: string): string {
  return path.join(skillCatalogDirs(roots).find((d) => d.scope === "global")!.dir, name);
}

describe("renameSkillDir", () => {
  it("moves the directory with its assets and updates SKILL.md name", () => {
    const roots = { home: home() };
    writeSkillFile(roots, "global", "linter", {
      description: "Lints code",
      body: "Run the linter.",
    });
    // An asset alongside SKILL.md must travel with the rename.
    writeFileSync(path.join(globalSkillDir(roots, "linter"), "helper.sh"), "echo hi\n");

    renameSkillDir(roots, "global", "linter", "formatter");

    expect(existsSync(globalSkillDir(roots, "linter"))).toBe(false);
    expect(existsSync(path.join(globalSkillDir(roots, "formatter"), "helper.sh"))).toBe(true);
    const skills = scanSkills(roots);
    expect(skills.map((s) => s.name)).toEqual(["formatter"]);
    expect(skills[0]!.body).toBe("Run the linter.");
    expect(
      readFileSync(path.join(globalSkillDir(roots, "formatter"), "SKILL.md"), "utf8"),
    ).toContain("name: formatter");
  });

  it("throws skill_exists / skill_not_found for a clash or missing source", () => {
    const roots = { home: home() };
    writeSkillFile(roots, "global", "a", { description: "a", body: "x" });
    writeSkillFile(roots, "global", "b", { description: "b", body: "y" });
    expect(() => renameSkillDir(roots, "global", "a", "b")).toThrow("skill_exists");
    expect(() => renameSkillDir(roots, "global", "ghost", "z")).toThrow("skill_not_found");
    // The clash left both skills intact.
    expect(
      scanSkills(roots)
        .map((s) => s.name)
        .sort(),
    ).toEqual(["a", "b"]);
  });

  it("handles a case-only rename on any filesystem", () => {
    const roots = { home: home() };
    writeSkillFile(roots, "global", "linter", { description: "l", body: "keep" });
    renameSkillDir(roots, "global", "linter", "Linter");
    expect(scanSkills(roots).map((s) => s.name)).toEqual(["Linter"]);
  });
});
