import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { createFileService } from "../src/services/files.ts";

/**
 * Unit tests for the Slice-13a file-navigation service (services/files.ts)
 * against REAL scratch dirs — the diff.test.ts convention (temp dirs cleaned in
 * afterEach). Covers directory listing (nested dirs, sizes, dirs-first order,
 * entry cap), bounded file reads (text / binary / image data URI / huge
 * truncation / oversized image → binary), and the containment rejections that
 * mirror editorLauncher's gate (absolute, `..` traversal, symlink escape, NUL,
 * missing, the root itself for a read).
 */

const tempDirs: string[] = [];
function makeTempDir(): string {
  const dir = mkdtempSync(nodePath.join(tmpdir(), "agent-deck-files-test-"));
  tempDirs.push(dir);
  // realpath so containment's realpath compare matches on macOS (/var symlink).
  return realpathSync(dir);
}
afterEach(() => {
  for (const dir of tempDirs.splice(0)) {
    try {
      rmSync(dir, { recursive: true, force: true });
    } catch {
      // best-effort
    }
  }
});

/** A project with a src/ subtree, a dotfile, a binary, and a nested dir. */
function makeProject(): string {
  const cwd = makeTempDir();
  mkdirSync(nodePath.join(cwd, "src", "lib"), { recursive: true });
  writeFileSync(nodePath.join(cwd, "src", "a.ts"), "export const a = 1;\n");
  writeFileSync(nodePath.join(cwd, "src", "lib", "util.ts"), "export const u = 2;\n");
  writeFileSync(nodePath.join(cwd, "README.md"), "# hello\n");
  writeFileSync(nodePath.join(cwd, ".env"), "SECRET=1\n");
  writeFileSync(nodePath.join(cwd, "bin.dat"), Buffer.from([0, 1, 2, 0, 255]));
  // A sibling OUTSIDE the project the containment gate must never reach.
  writeFileSync(nodePath.join(nodePath.dirname(cwd), "outside.txt"), "secret\n");
  return cwd;
}

describe("createFileService: listDirectory", () => {
  it("lists the project root (dirs first; dotfiles included; sizes reported)", async () => {
    const cwd = makeProject();
    const files = createFileService();
    const result = await files.listDirectory(cwd);
    expect(result.path).toBe("");
    expect(result.truncated).toBe(false);
    // The one directory sorts ahead of every file (dirs-first invariant).
    expect(result.entries[0]).toEqual({ name: "src", kind: "dir", size: null });
    // The files (order among them is localeCompare, asserted set-wise here).
    const filesByName = new Map(
      result.entries.filter((e) => e.kind === "file").map((e) => [e.name, e]),
    );
    expect(filesByName.get(".env")).toEqual({ name: ".env", kind: "file", size: 9 });
    expect(filesByName.get("README.md")).toEqual({ name: "README.md", kind: "file", size: 8 });
    expect(filesByName.get("bin.dat")).toEqual({ name: "bin.dat", kind: "file", size: 5 });
    // Files never precede a directory.
    const firstFileIndex = result.entries.findIndex((e) => e.kind === "file");
    const lastDirIndex =
      result.entries.length - 1 - [...result.entries].reverse().findIndex((e) => e.kind === "dir");
    expect(firstFileIndex).toBeGreaterThan(lastDirIndex);
  });

  it("lists a nested directory by its relative path", async () => {
    const cwd = makeProject();
    const files = createFileService();
    const result = await files.listDirectory(cwd, "src");
    expect(result.path).toBe("src");
    expect(result.entries).toEqual([
      { name: "lib", kind: "dir", size: null },
      { name: "a.ts", kind: "file", size: 20 },
    ]);
  });

  it('treats "." and "" as the project root', async () => {
    const cwd = makeProject();
    const files = createFileService();
    expect((await files.listDirectory(cwd, ".")).path).toBe("");
    expect((await files.listDirectory(cwd, "")).path).toBe("");
  });

  it("caps the listing at maxEntries and flags truncation", async () => {
    const cwd = makeTempDir();
    for (let i = 0; i < 6; i += 1) writeFileSync(nodePath.join(cwd, `f${i}.txt`), `${i}\n`);
    const files = createFileService({ maxEntries: 3 });
    const result = await files.listDirectory(cwd);
    expect(result.truncated).toBe(true);
    expect(result.entries).toHaveLength(3);
  });

  it("omits symlinked entries from the listing", async () => {
    const cwd = makeProject();
    try {
      symlinkSync(nodePath.dirname(cwd), nodePath.join(cwd, "escape-link"), "dir");
    } catch {
      return; // symlink creation may be unprivileged-denied on Windows — skip
    }
    const files = createFileService();
    const names = (await files.listDirectory(cwd)).entries.map((e) => e.name);
    expect(names).not.toContain("escape-link");
  });

  it("rejects a directory path that escapes the project (containment)", async () => {
    const cwd = makeProject();
    const files = createFileService();
    await expect(files.listDirectory(cwd, "..")).rejects.toThrow(/escapes/);
    await expect(files.listDirectory(cwd, "src/../../")).rejects.toThrow(/escapes/);
  });

  it("rejects listing a file as a directory", async () => {
    const cwd = makeProject();
    const files = createFileService();
    await expect(files.listDirectory(cwd, "README.md")).rejects.toThrow(/not a directory/);
  });
});

describe("createFileService: readFile", () => {
  it("reads a text file with its true byte length, untruncated", async () => {
    const cwd = makeProject();
    const files = createFileService();
    const result = await files.readFile(cwd, "src/a.ts");
    expect(result).toEqual({
      contentKind: "text",
      content: "export const a = 1;\n",
      byteLength: 20,
      truncated: false,
    });
  });

  it("caps a huge text file and flags truncation (byteLength stays the true size)", async () => {
    const cwd = makeTempDir();
    const body = "x".repeat(5_000);
    writeFileSync(nodePath.join(cwd, "big.txt"), body);
    const files = createFileService({ maxReadBytes: 1_000 });
    const result = await files.readFile(cwd, "big.txt");
    expect(result.contentKind).toBe("text");
    expect(result.truncated).toBe(true);
    expect(result.content).toHaveLength(1_000);
    expect(result.byteLength).toBe(5_000);
  });

  it("flags a binary file (NUL byte) with empty content", async () => {
    const cwd = makeProject();
    const files = createFileService();
    const result = await files.readFile(cwd, "bin.dat");
    expect(result).toEqual({
      contentKind: "binary",
      content: "",
      byteLength: 5,
      truncated: false,
    });
  });

  it("returns a recognised image as a data URI", async () => {
    const cwd = makeTempDir();
    // 1x1 transparent PNG.
    const png = Buffer.from(
      "89504e470d0a1a0a0000000d494844520000000100000001080600000" +
        "01f15c4890000000d49444154789c6360000002000100" +
        "05fe02fea7f35d990000000049454e44ae426082",
      "hex",
    );
    writeFileSync(nodePath.join(cwd, "pixel.png"), png);
    const files = createFileService();
    const result = await files.readFile(cwd, "pixel.png");
    expect(result.contentKind).toBe("image");
    expect(result.truncated).toBe(false);
    expect(result.byteLength).toBe(png.length);
    expect(result.content).toBe(`data:image/png;base64,${png.toString("base64")}`);
  });

  it("degrades an oversized image to binary (can't inline it)", async () => {
    const cwd = makeTempDir();
    writeFileSync(nodePath.join(cwd, "big.png"), Buffer.alloc(4_096, 7));
    const files = createFileService({ maxImageBytes: 1_024 });
    const result = await files.readFile(cwd, "big.png");
    expect(result).toEqual({
      contentKind: "binary",
      content: "",
      byteLength: 4_096,
      truncated: false,
    });
  });

  it("rejects containment violations exactly like editorLauncher", async () => {
    const cwd = makeProject();
    const files = createFileService();
    await expect(files.readFile(cwd, "../outside.txt")).rejects.toThrow(/escapes/);
    await expect(files.readFile(cwd, "src/../../outside.txt")).rejects.toThrow(/escapes/);
    await expect(files.readFile(cwd, nodePath.resolve(cwd, "src/a.ts"))).rejects.toThrow(
      /must be relative/,
    );
    await expect(files.readFile(cwd, "src/missing.ts")).rejects.toThrow(/not found/);
    await expect(files.readFile(cwd, "src/a.ts\0x")).rejects.toThrow(/invalid path/);
  });

  it("rejects reading the project root itself (allowBase is false for reads)", async () => {
    const cwd = makeProject();
    const files = createFileService();
    await expect(files.readFile(cwd, ".")).rejects.toThrow(/escapes/);
  });

  it("rejects reading a directory as a file", async () => {
    const cwd = makeProject();
    const files = createFileService();
    await expect(files.readFile(cwd, "src")).rejects.toThrow(/not a file/);
  });

  it("rejects a symlink that escapes the project (realpath containment)", async () => {
    const cwd = makeProject();
    try {
      symlinkSync(
        nodePath.join(nodePath.dirname(cwd), "outside.txt"),
        nodePath.join(cwd, "link.txt"),
      );
    } catch {
      return; // symlink creation may be unprivileged-denied on Windows — skip
    }
    const files = createFileService();
    await expect(files.readFile(cwd, "link.txt")).rejects.toThrow(/escapes/);
  });
});
