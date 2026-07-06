import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { promptCatalogDirs } from "../src/paths.ts";
import { scanPrompts } from "../src/scanner.ts";
import { renamePromptFile, writePromptFile } from "../src/writer.ts";

/**
 * Prompt rename (native RenameResourceSheet, 8.3): move a prompt-template file
 * within its scope, preserving body/description/unknown frontmatter and keeping
 * the `name` field in sync with the filename pi exposes as /prompt:<name>.
 */

function home(): string {
  return mkdtempSync(path.join(tmpdir(), "prompt-rename-home-"));
}

function globalPromptPath(roots: { home: string }, name: string): string {
  const dir = promptCatalogDirs(roots).find((d) => d.scope === "global")!.dir;
  return path.join(dir, `${name}.md`);
}

describe("renamePromptFile", () => {
  it("moves the file, preserves content, and updates the name field", () => {
    const roots = { home: home() };
    writePromptFile(roots, "global", "review", {
      description: "Review the diff",
      body: "# Review\n\nCheck the changes.",
    });

    const to = renamePromptFile(roots, "global", "review", "audit");

    // Old gone, new present, catalog reflects only the new name.
    expect(existsSync(globalPromptPath(roots, "review"))).toBe(false);
    expect(existsSync(to)).toBe(true);
    const names = scanPrompts(roots).map((p) => p.name);
    expect(names).toContain("audit");
    expect(names).not.toContain("review");

    // Body + description carried over; frontmatter name matches the new file.
    const audit = scanPrompts(roots).find((p) => p.name === "audit")!;
    expect(audit.description).toBe("Review the diff");
    expect(audit.body).toBe("# Review\n\nCheck the changes.");
    expect(readFileSync(to, "utf8")).toContain("name: audit");
  });

  it("preserves unknown frontmatter fields across the rename", () => {
    const roots = { home: home() };
    const from = globalPromptPath(roots, "orig");
    writePromptFile(roots, "global", "orig", { body: "b" });
    // Inject an unknown field the writer doesn't model.
    writeFileSync(from, `---\nname: orig\nauthor: alex\ncustom: keepme\n---\n\nb\n`);

    const to = renamePromptFile(roots, "global", "orig", "renamed");
    const text = readFileSync(to, "utf8");
    expect(text).toContain("author: alex");
    expect(text).toContain("custom: keepme");
    expect(text).toContain("name: renamed");
  });

  it("throws prompt_exists when the target name is already taken", () => {
    const roots = { home: home() };
    writePromptFile(roots, "global", "a", { body: "x" });
    writePromptFile(roots, "global", "b", { body: "y" });
    expect(() => renamePromptFile(roots, "global", "a", "b")).toThrow("prompt_exists");
    // Both originals untouched after the failed rename.
    expect(
      scanPrompts(roots)
        .map((p) => p.name)
        .sort(),
    ).toEqual(["a", "b"]);
  });

  it("throws prompt_not_found when the source is missing", () => {
    const roots = { home: home() };
    expect(() => renamePromptFile(roots, "global", "ghost", "whatever")).toThrow(
      "prompt_not_found",
    );
  });

  it("is a no-op when the name is unchanged", () => {
    const roots = { home: home() };
    writePromptFile(roots, "global", "same", { body: "z" });
    expect(() => renamePromptFile(roots, "global", "same", "same")).not.toThrow();
    expect(scanPrompts(roots).map((p) => p.name)).toEqual(["same"]);
  });

  it("handles a case-only rename on both case-sensitive and case-insensitive FS", () => {
    const roots = { home: home() };
    writePromptFile(roots, "global", "review", { description: "d", body: "keep me" });

    // On macOS/Windows `to` resolves onto the same file (no false 409); on Linux
    // it's a distinct file. Either way the result is one prompt named "Review".
    const to = renamePromptFile(roots, "global", "review", "Review");
    expect(existsSync(to)).toBe(true);
    expect(scanPrompts(roots).map((p) => p.name)).toEqual(["Review"]);
    const text = readFileSync(to, "utf8");
    expect(text).toContain("keep me");
    expect(text).toContain("name: Review");
  });
});
