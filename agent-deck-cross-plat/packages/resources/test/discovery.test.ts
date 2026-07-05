import { mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { detectProjectType, discoverProjectsInRoot } from "../src/discovery.ts";

function makeRoot(): string {
  return mkdtempSync(path.join(tmpdir(), "discover-"));
}

function makeProject(root: string, name: string, files: Record<string, string>): string {
  const dir = path.join(root, name);
  mkdirSync(dir, { recursive: true });
  for (const [file, content] of Object.entries(files)) {
    const full = path.join(dir, file);
    mkdirSync(path.dirname(full), { recursive: true });
    writeFileSync(full, content);
  }
  return dir;
}

describe("detectProjectType", () => {
  it("detects marker-file project types", () => {
    const root = makeRoot();
    expect(detectProjectType(makeProject(root, "r", { "Cargo.toml": "" }))).toBe("rust");
    expect(detectProjectType(makeProject(root, "g", { "go.mod": "" }))).toBe("go");
    expect(detectProjectType(makeProject(root, "s", { "Package.swift": "" }))).toBe("swift");
    expect(detectProjectType(makeProject(root, "p", { "pyproject.toml": "" }))).toBe("python");
    expect(detectProjectType(makeProject(root, "rb", { Gemfile: "" }))).toBe("ruby");
  });

  it("detects JS frameworks from package.json deps", () => {
    const root = makeRoot();
    const react = makeProject(root, "react-app", {
      "package.json": JSON.stringify({ dependencies: { react: "19" } }),
    });
    expect(detectProjectType(react)).toBe("react");
    const next = makeProject(root, "next-app", {
      "package.json": JSON.stringify({ dependencies: { next: "15", react: "19" } }),
    });
    expect(detectProjectType(next)).toBe("nextjs");
    const bare = makeProject(root, "lib", { "package.json": "{}" });
    expect(detectProjectType(bare)).toBe("node");
  });

  it("git-only dir is 'git'; empty dir is 'unknown'", () => {
    const root = makeRoot();
    expect(detectProjectType(makeProject(root, "repo", { ".git/HEAD": "ref: main" }))).toBe("git");
    expect(detectProjectType(makeProject(root, "empty", {}))).toBe("unknown");
  });

  it("ignores a huge package.json rather than parsing it", () => {
    const root = makeRoot();
    const big = JSON.stringify({ dependencies: { react: "19", filler: "x".repeat(600 * 1024) } });
    const dir = makeProject(root, "bloated", { "package.json": big });
    // Over the size cap → deps not consulted → falls back to bare node.
    expect(detectProjectType(dir)).toBe("node");
  });
});

describe("discoverProjectsInRoot", () => {
  it("finds project subdirectories one level deep and skips non-projects", () => {
    const root = makeRoot();
    makeProject(root, "alpha", { ".git/HEAD": "x" });
    makeProject(root, "beta", { "package.json": JSON.stringify({ dependencies: { vue: "3" } }) });
    makeProject(root, "notaproject", { "readme.txt": "hi" });
    mkdirSync(path.join(root, ".hidden"), { recursive: true });

    const found = discoverProjectsInRoot(root);
    const names = found.map((c) => c.name);
    expect(names).toContain("alpha");
    expect(names).toContain("beta");
    expect(names).not.toContain("notaproject");
    expect(found.find((c) => c.name === "beta")?.type).toBe("vue");
  });

  it("skips symlinked children (no traversal out of the root)", () => {
    const root = makeRoot();
    const outside = makeRoot();
    makeProject(outside, "external-repo", { ".git/HEAD": "x" });
    makeProject(root, "real", { ".git/HEAD": "x" });
    symlinkSync(path.join(outside, "external-repo"), path.join(root, "linked"));

    const names = discoverProjectsInRoot(root).map((c) => c.name);
    expect(names).toContain("real");
    expect(names).not.toContain("linked"); // symlinked child skipped
  });
});
