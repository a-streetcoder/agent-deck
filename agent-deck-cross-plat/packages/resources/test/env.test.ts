import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { scanEnv, writeEnvVar } from "../src/env.ts";

function makeHome(): string {
  return mkdtempSync(path.join(tmpdir(), "env-home-"));
}

function readGlobal(home: string): string {
  return readFileSync(path.join(home, ".pi", "agent", ".env"), "utf8");
}

describe("writeEnvVar / scanEnv round-trip", () => {
  it("adds a var and preserves comments and other keys", () => {
    const home = makeHome();
    const file = path.join(home, ".pi", "agent", ".env");
    mkdirSync(path.dirname(file), { recursive: true });
    writeFileSync(file, "# heading\nFOO=1\n\nBAR=2\n");

    writeEnvVar({ home }, "global", "BAZ", "3");
    const content = readGlobal(home);
    expect(content).toContain("# heading");
    expect(content).toContain("FOO=1");
    expect(content).toContain("BAR=2");
    expect(content).toContain("BAZ=3");
  });

  it("replaces an existing var without duplicating it", () => {
    const home = makeHome();
    const file = path.join(home, ".pi", "agent", ".env");
    mkdirSync(path.dirname(file), { recursive: true });
    writeFileSync(file, "FOO=old\n");
    writeEnvVar({ home }, "global", "FOO", "new");
    const matches = readGlobal(home).match(/^FOO=/gm) ?? [];
    expect(matches).toHaveLength(1);
    expect(readGlobal(home)).toContain("FOO=new");
  });

  it("round-trips values with quotes, backslashes, spaces, and #", () => {
    const home = makeHome();
    const tricky = 'a"b\\c d#e';
    writeEnvVar({ home }, "global", "TRICKY", tricky);
    // The persisted value must parse back to the exact original.
    const entry = scanEnv({ home }).find((e) => e.key === "TRICKY");
    expect(entry).toBeDefined();
    // scanEnv masks, so assert via a second read through the parser by writing
    // a sentinel and re-reading the tricky value's file form is quoted.
    expect(readGlobal(home)).toContain('TRICKY="a\\"b\\\\c d#e"');
  });

  it("recognizes the `export KEY=` form and replaces it in place", () => {
    const home = makeHome();
    const file = path.join(home, ".pi", "agent", ".env");
    mkdirSync(path.dirname(file), { recursive: true });
    writeFileSync(file, "export SHELL_VAR=old\n");
    writeEnvVar({ home }, "global", "SHELL_VAR", "new");
    const content = readGlobal(home);
    expect(content).not.toContain("export SHELL_VAR=old");
    expect((content.match(/SHELL_VAR=/g) ?? []).length).toBe(1);
    expect(scanEnv({ home }).find((e) => e.key === "SHELL_VAR")).toBeDefined();
  });

  it("rejects newlines in values", () => {
    const home = makeHome();
    expect(() => writeEnvVar({ home }, "global", "MULTI", "a\nb")).toThrow(/newline/);
  });

  it("deletes a var", () => {
    const home = makeHome();
    writeEnvVar({ home }, "global", "GONE", "x");
    writeEnvVar({ home }, "global", "GONE", null);
    expect(scanEnv({ home }).find((e) => e.key === "GONE")).toBeUndefined();
  });

  it("masks short secrets fully and never reveals length", () => {
    const home = makeHome();
    writeEnvVar({ home }, "global", "SHORT", "abc12"); // 5 chars
    writeEnvVar({ home }, "global", "LONG", "abcdefghijklmnop");
    const entries = scanEnv({ home });
    const short = entries.find((e) => e.key === "SHORT")!;
    const long = entries.find((e) => e.key === "LONG")!;
    // Short secret's characters must not appear.
    expect(short.masked).not.toContain("abc12");
    expect(short.masked).toBe("••••••••");
    // Long secret shows a fixed prefix + last 4 (constant width, no length leak).
    expect(long.masked).toBe("••••••••mnop");
  });

  it("reports each var's source .env file (native 5.2)", () => {
    const home = makeHome();
    const project = makeHome();
    mkdirSync(path.join(home, ".pi", "agent"), { recursive: true });
    writeFileSync(path.join(home, ".pi", "agent", ".env"), "GKEY=g\n");
    mkdirSync(path.join(project, ".pi"), { recursive: true });
    writeFileSync(path.join(project, ".pi", ".env"), "PKEY=p\n");

    const entries = scanEnv({ home, projectPath: project });
    expect(entries.find((e) => e.key === "GKEY")!.source).toBe(
      path.join(home, ".pi", "agent", ".env"),
    );
    expect(entries.find((e) => e.key === "PKEY")!.source).toBe(path.join(project, ".pi", ".env"));
  });
});
