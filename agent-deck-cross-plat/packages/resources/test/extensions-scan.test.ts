import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { scanExtensions } from "../src/scanner.ts";

/**
 * scanExtensions discovers the user's own extension files in the standard pi
 * locations (global ~/.pi/agent/extensions + the project's .pi/extensions), so
 * they surface without being added by hand — the extension-management gap the
 * port had (only a manual registry, no discovery).
 */

function makeHome(): string {
  return mkdtempSync(path.join(tmpdir(), "res-home-"));
}
function makeProject(): string {
  return mkdtempSync(path.join(tmpdir(), "res-proj-"));
}
function write(dir: string, name: string, contents = "export default {};\n"): void {
  mkdirSync(dir, { recursive: true });
  writeFileSync(path.join(dir, name), contents);
}

describe("scanExtensions", () => {
  it("discovers global + project extensions with their scope", () => {
    const home = makeHome();
    const projectPath = makeProject();
    write(path.join(home, ".pi", "agent", "extensions"), "logger.ts");
    write(path.join(projectPath, ".pi", "extensions"), "linter.js");

    const found = scanExtensions({ home, projectPath });
    const byName = new Map(found.map((e) => [e.name, e]));
    expect(byName.get("logger.ts")?.scope).toBe("global");
    expect(byName.get("linter.js")?.scope).toBe("project");
    expect(byName.get("logger.ts")?.path).toBe(
      path.join(home, ".pi", "agent", "extensions", "logger.ts"),
    );
  });

  it("only matches TS/JS extension files, skipping other files and directories", () => {
    const home = makeHome();
    const dir = path.join(home, ".pi", "agent", "extensions");
    write(dir, "keep.mjs");
    write(dir, "README.md");
    write(dir, "notes.txt");
    mkdirSync(path.join(dir, "a-directory.ts"), { recursive: true }); // a dir named like a .ts

    const names = scanExtensions({ home }).map((e) => e.name);
    expect(names).toEqual(["keep.mjs"]);
  });

  it("returns nothing when the extension dirs don't exist (no throw)", () => {
    expect(scanExtensions({ home: makeHome(), projectPath: makeProject() })).toEqual([]);
  });

  it("has no project entries when no project path is set", () => {
    const home = makeHome();
    write(path.join(home, ".pi", "agent", "extensions"), "g.ts");
    const found = scanExtensions({ home });
    expect(found.every((e) => e.scope === "global")).toBe(true);
    expect(found).toHaveLength(1);
  });
});
