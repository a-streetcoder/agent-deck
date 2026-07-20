import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { Effect } from "effect";
import { afterEach, describe, expect, it, vi } from "vitest";
import { parseNameStatusZ, parseNumstatZ } from "../src/git.ts";
import { makeSessionDiff, type SessionDiffShape } from "../src/services/diff.ts";

// Real git repos + spawns compete with the rest of the suite (node-pty,
// fake-pi) for the machine: the 5s default trips under full-suite load. Same
// headroom precedent as the doctor tests.
vi.setConfig({ testTimeout: 20_000 });

/**
 * SessionDiff service tests (Slice 9) against REAL scratch git repos — the
 * skill-repo-import.test.ts convention (execFileSync git in a temp dir). The
 * scenarios mirror the donor's review-diff surface: modify / staged add /
 * delete / rename / binary / untracked, huge-file truncation, set capping,
 * fingerprint-based change detection, and the non-repo guard.
 */

const tempDirs: string[] = [];
function makeTempDir(): string {
  const dir = mkdtempSync(path.join(tmpdir(), "agent-deck-diff-test-"));
  tempDirs.push(dir);
  return dir;
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

function git(cwd: string, args: string[]): void {
  execFileSync("git", args, { cwd, stdio: "ignore" });
}

/** A repo with one commit containing a.txt, b.txt, c.txt. */
function makeRepo(): string {
  const repo = makeTempDir();
  git(repo, ["init", "-b", "main"]);
  git(repo, ["config", "user.email", "t@example.com"]);
  git(repo, ["config", "user.name", "Test"]);
  writeFileSync(path.join(repo, "a.txt"), "line1\nline2\nline3\n");
  writeFileSync(path.join(repo, "b.txt"), "bye\n");
  writeFileSync(path.join(repo, "c.txt"), "alpha\nbeta\ngamma\ndelta\n");
  git(repo, ["add", "-A"]);
  git(repo, ["commit", "-m", "init"]);
  return repo;
}

const run = <A>(effect: Effect.Effect<A>): Promise<A> => Effect.runPromise(effect);

const listFiles = (diff: SessionDiffShape, sessionId: string, cwd: string) =>
  run(diff.listFiles(sessionId, cwd));

describe("git -z parsers", () => {
  it("parseNameStatusZ handles plain entries and renames (two paths)", () => {
    const entries = parseNameStatusZ("M\0a.txt\0R100\0old.txt\0new.txt\0D\0gone.txt\0");
    expect(entries).toEqual([
      { status: "M", path: "a.txt" },
      { status: "R", path: "new.txt", oldPath: "old.txt" },
      { status: "D", path: "gone.txt" },
    ]);
  });

  it("parseNumstatZ handles plain, rename, and binary records", () => {
    const entries = parseNumstatZ(
      "3\t1\ta.txt\0" + "0\t0\t\0old.txt\0new.txt\0" + "-\t-\tbin.dat\0",
    );
    expect(entries).toEqual([
      { path: "a.txt", insertions: 3, deletions: 1 },
      { path: "new.txt", oldPath: "old.txt", insertions: 0, deletions: 0 },
      { path: "bin.dat", insertions: null, deletions: null },
    ]);
  });
});

describe("SessionDiff service (services/diff.ts)", () => {
  it("a non-repo cwd answers repo:false with an empty set, never an error", async () => {
    const dir = makeTempDir();
    const diff = makeSessionDiff();
    expect(await listFiles(diff, "s1", dir)).toEqual({ repo: false, files: [], truncated: false });
    // First refresh of a non-repo session is NOT a change (empty vs empty).
    const refreshed = await run(diff.refresh("s1", dir));
    expect(refreshed.changed).toBe(false);
    // fileDiff on any path is the clean empty answer.
    expect(await run(diff.fileDiff("s1", dir, "whatever.txt"))).toEqual({
      path: "whatever.txt",
      diff: "",
      truncated: false,
      binary: false,
    });
  });

  it("lists modify / staged add / delete / rename / binary / untracked with stats", async () => {
    const repo = makeRepo();
    // Modify (unstaged), delete, pure rename (staged), staged add, binary
    // (staged), untracked text file, untracked binary.
    writeFileSync(path.join(repo, "a.txt"), "line1\nCHANGED\nline3\nline4\n");
    rmSync(path.join(repo, "b.txt"));
    git(repo, ["mv", "c.txt", "renamed.txt"]);
    writeFileSync(path.join(repo, "staged.txt"), "fresh\n");
    git(repo, ["add", "staged.txt"]);
    writeFileSync(path.join(repo, "bin.dat"), Buffer.from([0, 1, 2, 0, 255]));
    git(repo, ["add", "bin.dat"]);
    mkdirSync(path.join(repo, "sub"));
    writeFileSync(path.join(repo, "sub", "untracked.txt"), "one\ntwo\n");
    writeFileSync(path.join(repo, "untracked.bin"), Buffer.from([0, 7, 0, 9]));

    const diff = makeSessionDiff();
    const set = await listFiles(diff, "s1", repo);
    expect(set.repo).toBe(true);
    expect(set.truncated).toBe(false);
    const byPath = new Map(set.files.map((f) => [f.path, f]));

    expect(byPath.get("a.txt")).toEqual({
      path: "a.txt",
      status: "M",
      insertions: 2,
      deletions: 1,
      binary: false,
    });
    expect(byPath.get("b.txt")).toMatchObject({ status: "D", insertions: 0, deletions: 1 });
    expect(byPath.get("renamed.txt")).toEqual({
      path: "renamed.txt",
      oldPath: "c.txt",
      status: "R",
      insertions: 0,
      deletions: 0,
      binary: false,
    });
    expect(byPath.get("staged.txt")).toMatchObject({ status: "A", insertions: 1, deletions: 0 });
    expect(byPath.get("bin.dat")).toMatchObject({
      status: "A",
      insertions: null,
      deletions: null,
      binary: true,
    });
    // Untracked files carry synthesized stats (vs /dev/null).
    expect(byPath.get("sub/untracked.txt")).toEqual({
      path: "sub/untracked.txt",
      status: "?",
      insertions: 2,
      deletions: 0,
      binary: false,
    });
    expect(byPath.get("untracked.bin")).toMatchObject({
      status: "?",
      insertions: null,
      deletions: null,
      binary: true,
    });
    // Sorted by path (the service's localeCompare order), no strays.
    const paths = set.files.map((f) => f.path);
    expect(paths).toEqual([...paths].sort((a, b) => a.localeCompare(b)));
    expect(set.files).toHaveLength(7);
  });

  it("computes unified diffs: tracked, rename (both pathspecs), untracked synthesis, binary, unknown", async () => {
    const repo = makeRepo();
    writeFileSync(path.join(repo, "a.txt"), "line1\nCHANGED\nline3\n");
    git(repo, ["mv", "c.txt", "renamed.txt"]);
    writeFileSync(path.join(repo, "bin.dat"), Buffer.from([0, 1, 2]));
    git(repo, ["add", "bin.dat"]);
    writeFileSync(path.join(repo, "fresh.txt"), "hello\nworld\n");

    const diff = makeSessionDiff();

    const tracked = await run(diff.fileDiff("s1", repo, "a.txt"));
    expect(tracked.binary).toBe(false);
    expect(tracked.truncated).toBe(false);
    expect(tracked.diff).toContain("--- a/a.txt");
    expect(tracked.diff).toContain("+++ b/a.txt");
    expect(tracked.diff).toContain("-line2");
    expect(tracked.diff).toContain("+CHANGED");

    // The rename rides both pathspecs, so git reports it AS a rename.
    const renamed = await run(diff.fileDiff("s1", repo, "renamed.txt"));
    expect(renamed.diff).toContain("rename from c.txt");
    expect(renamed.diff).toContain("rename to renamed.txt");

    // Untracked synthesis against /dev/null (donor's readUntrackedReviewDiffs).
    const untracked = await run(diff.fileDiff("s1", repo, "fresh.txt"));
    expect(untracked.diff).toContain("+++ b/fresh.txt");
    expect(untracked.diff).toContain("+hello");
    expect(untracked.diff).toContain("+world");

    // Binary: flagged, no patch body.
    const binary = await run(diff.fileDiff("s1", repo, "bin.dat"));
    expect(binary).toEqual({ path: "bin.dat", diff: "", truncated: false, binary: true });

    // Not in the changed-file set (this is also the traversal guard).
    const unknown = await run(diff.fileDiff("s1", repo, "../outside.txt"));
    expect(unknown).toEqual({ path: "../outside.txt", diff: "", truncated: false, binary: false });
  });

  it("caps a huge file's diff and flags truncation", async () => {
    const repo = makeRepo();
    const huge = Array.from({ length: 5_000 }, (_, i) => `added line ${i}`).join("\n");
    writeFileSync(path.join(repo, "a.txt"), `${huge}\n`);
    const diff = makeSessionDiff({ maxPatchChars: 2_000 });
    const result = await run(diff.fileDiff("s1", repo, "a.txt"));
    expect(result.truncated).toBe(true);
    expect(result.diff.length).toBeLessThanOrEqual(2_000);
    expect(result.diff).toContain("diff --git");
  });

  it("caps the changed-file set at maxFiles and flags truncation", async () => {
    const repo = makeRepo();
    for (let i = 0; i < 6; i += 1) {
      writeFileSync(path.join(repo, `new-${i}.txt`), `${i}\n`);
    }
    const diff = makeSessionDiff({ maxFiles: 3 });
    const set = await listFiles(diff, "s1", repo);
    expect(set.truncated).toBe(true);
    expect(set.files).toHaveLength(3);
  });

  it("refresh reports changed only when the set differs (fingerprint compare)", async () => {
    const repo = makeRepo();
    const diff = makeSessionDiff();
    // A clean tree's first refresh: empty vs the empty baseline — unchanged.
    const clean = await run(diff.refresh("s1", repo));
    expect(clean.changed).toBe(false);
    expect(clean.set).toEqual({ repo: true, files: [], truncated: false });

    // A turn writes a file: the next refresh reports the change.
    writeFileSync(path.join(repo, "a.txt"), "line1\nline2\nline3\nmore\n");
    const dirty = await run(diff.refresh("s1", repo));
    expect(dirty.changed).toBe(true);
    expect(dirty.set.files.map((f) => f.path)).toEqual(["a.txt"]);

    // Nothing else changed: the following refresh is quiet.
    const same = await run(diff.refresh("s1", repo));
    expect(same.changed).toBe(false);

    // Stats changing (more lines in the same file) IS a change.
    writeFileSync(path.join(repo, "a.txt"), "line1\nline2\nline3\nmore\nlines\n");
    expect((await run(diff.refresh("s1", repo))).changed).toBe(true);
  });

  it("listFiles serves the cache until a refresh recomputes; drop clears it", async () => {
    const repo = makeRepo();
    const diff = makeSessionDiff();
    expect((await listFiles(diff, "s1", repo)).files).toHaveLength(0);

    writeFileSync(path.join(repo, "z.txt"), "zzz\n");
    // Cached: the new untracked file is not visible yet.
    expect((await listFiles(diff, "s1", repo)).files).toHaveLength(0);
    // Refresh recomputes and updates the cache.
    expect((await run(diff.refresh("s1", repo))).set.files).toHaveLength(1);
    expect((await listFiles(diff, "s1", repo)).files).toHaveLength(1);
    // Another session id has its own cache entry.
    expect((await listFiles(diff, "s2", repo)).files).toHaveLength(1);

    // drop() forgets the session; the next listFiles recomputes fresh.
    rmSync(path.join(repo, "z.txt"));
    await run(diff.drop("s1"));
    expect((await listFiles(diff, "s1", repo)).files).toHaveLength(0);
  });

  it("a fresh repo with no commits diffs staged files against the empty tree", async () => {
    const repo = makeTempDir();
    git(repo, ["init", "-b", "main"]);
    git(repo, ["config", "user.email", "t@example.com"]);
    git(repo, ["config", "user.name", "Test"]);
    writeFileSync(path.join(repo, "first.txt"), "hello\n");
    git(repo, ["add", "first.txt"]);

    const diff = makeSessionDiff();
    const set = await listFiles(diff, "s1", repo);
    expect(set.repo).toBe(true);
    expect(set.files).toEqual([
      { path: "first.txt", status: "A", insertions: 1, deletions: 0, binary: false },
    ]);
    const patch = await run(diff.fileDiff("s1", repo, "first.txt"));
    expect(patch.diff).toContain("+hello");
  });
});
