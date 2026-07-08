import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { deleteLoopFile, duplicateLoop, loopsDir, scanLoops, writeLoopFile } from "../src/loops.ts";

function makeHome(): string {
  return mkdtempSync(path.join(tmpdir(), "loops-home-"));
}

describe("loop definition store", () => {
  it("creates, round-trips, updates, and deletes a loop", () => {
    const home = makeHome();
    const roots = { home };

    const filePath = writeLoopFile(roots, {
      name: "Fix Flaky Tests",
      description: "Iterate until the suite is green",
      goal: "Find and fix the flaky test.",
      structure: "singleAgent",
      agentName: "coder",
      maxIterations: 5,
      validationCommand: "pnpm test",
      writeTarget: "currentCheckout",
    });
    // Slugged filename under the loops dir; goal is the markdown body.
    expect(filePath).toBe(path.join(loopsDir(roots), "fix-flaky-tests.loop.md"));
    const raw = readFileSync(filePath, "utf8");
    expect(raw).toContain("name: Fix Flaky Tests");
    expect(raw).toContain("maxIterations: 5");
    expect(raw).toContain("Find and fix the flaky test.");

    const [loop] = scanLoops(roots);
    expect(loop).toMatchObject({
      name: "Fix Flaky Tests",
      description: "Iterate until the suite is green",
      goal: "Find and fix the flaky test.",
      structure: "singleAgent",
      agentName: "coder",
      maxIterations: 5,
      validationCommand: "pnpm test",
      writeTarget: "currentCheckout",
      source: "user",
    });

    // An update by the same name preserves the file + changes fields.
    writeLoopFile(roots, { name: "Fix Flaky Tests", maxIterations: 8 });
    const updated = scanLoops(roots).find((l) => l.name === "Fix Flaky Tests")!;
    expect(updated.maxIterations).toBe(8);
    expect(updated.goal).toBe("Find and fix the flaky test."); // body preserved

    deleteLoopFile(roots, "Fix Flaky Tests");
    expect(scanLoops(roots)).toEqual([]);
  });

  it("clamps maxIterations into 1..20 and defaults the structure/writeTarget", () => {
    const home = makeHome();
    const roots = { home };
    writeLoopFile(roots, { name: "big", maxIterations: 999, goal: "g" });
    writeLoopFile(roots, { name: "small", maxIterations: 0, goal: "g" });
    const loops = scanLoops(roots);
    expect(loops.find((l) => l.name === "big")!.maxIterations).toBe(20);
    expect(loops.find((l) => l.name === "small")!.maxIterations).toBe(1);
    // Unset structure/writeTarget default sensibly on read.
    expect(loops.find((l) => l.name === "big")!.structure).toBe("singleAgent");
    expect(loops.find((l) => l.name === "big")!.writeTarget).toBe("artifactMarkdown");
  });

  it("preserves unknown frontmatter from a native .loop.md on update", () => {
    const home = makeHome();
    const roots = { home };
    const filePath = writeLoopFile(roots, { name: "native", goal: "g" });
    // Inject a native-only field an external app wrote.
    writeFileSync(
      filePath,
      readFileSync(filePath, "utf8").replace("---\n\n", "checkerRubric: be strict\n---\n\n"),
    );
    writeLoopFile(roots, { name: "native", description: "updated" });
    expect(readFileSync(filePath, "utf8")).toContain("checkerRubric: be strict");
  });

  it("edits a loop whose filename doesn't match its name slug, in place (no orphan)", () => {
    const home = makeHome();
    const roots = { home };
    // A native-style file whose filename ≠ slug(name).
    const dir = loopsDir(roots);
    mkdirSync(dir, { recursive: true });
    const oddPath = path.join(dir, "custom-file.loop.md");
    writeFileSync(oddPath, "---\nname: Renamed Loop\nmaxIterations: 2\n---\n\nDo the thing.\n");

    // Editing by name must update THAT file, not create renamed-loop.loop.md.
    writeLoopFile(roots, { name: "Renamed Loop", maxIterations: 7 });
    expect(existsSync(path.join(dir, "renamed-loop.loop.md"))).toBe(false); // no orphan created
    expect(readFileSync(oddPath, "utf8")).toContain("maxIterations: 7");
    expect(scanLoops(roots)).toHaveLength(1);

    // Delete by name removes the actual file.
    deleteLoopFile(roots, "Renamed Loop");
    expect(existsSync(oddPath)).toBe(false);
  });

  it("duplicates a loop as 'Copy of X', de-duplicating on repeat", () => {
    const home = makeHome();
    const roots = { home };
    writeLoopFile(roots, {
      name: "Nightly",
      goal: "run nightly",
      maxIterations: 4,
      validationCommand: "make check",
      agentName: "coder",
    });

    const first = duplicateLoop(roots, "Nightly");
    expect(first).toBe("Copy of Nightly");
    const copy = scanLoops(roots).find((l) => l.name === "Copy of Nightly")!;
    expect(copy).toMatchObject({
      goal: "run nightly",
      maxIterations: 4,
      validationCommand: "make check",
      agentName: "coder",
    });

    // A second duplicate of the same source gets a numbered name.
    expect(duplicateLoop(roots, "Nightly")).toBe("Copy of Nightly (2)");
    expect(scanLoops(roots)).toHaveLength(3);

    expect(() => duplicateLoop(roots, "Ghost")).toThrow("loop_not_found");
  });

  it("rejects a different name that collides on the same slug", () => {
    const home = makeHome();
    const roots = { home };
    writeLoopFile(roots, { name: "My Loop", goal: "g" });
    expect(() => writeLoopFile(roots, { name: "my-loop", goal: "g2" })).toThrow(
      "loop_slug_conflict",
    );
  });
});
