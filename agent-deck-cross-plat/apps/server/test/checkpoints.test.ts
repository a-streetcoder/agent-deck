import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { makeCheckpointService, type CheckpointServiceShape } from "../src/services/checkpoints.ts";

/**
 * Checkpoint capture service tests (Slice 18a) against REAL scratch git repos —
 * the diff.test.ts convention (execFileSync git in a temp dir). These exercise
 * the two-half capture directly (no pi needed): the hidden-git-ref workspace
 * capture (temp-index tree-capture that never touches the user's real index /
 * working tree), the wholesale session-file snapshot, the non-git degrade, the
 * per-turn dedup, and the retention cap's prune of the oldest snapshot + ref.
 */

vi.setConfig({ testTimeout: 20_000 });

const tempDirs: string[] = [];
function makeTempDir(prefix: string): string {
  const dir = mkdtempSync(path.join(tmpdir(), prefix));
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

function git(cwd: string, args: string[]): string {
  return execFileSync("git", args, { cwd, encoding: "utf8" });
}

/** A repo with one commit containing README.md. */
function makeRepo(): string {
  const repo = makeTempDir("agent-deck-ckpt-repo-");
  git(repo, ["init", "-b", "main"]);
  git(repo, ["config", "user.email", "t@example.com"]);
  git(repo, ["config", "user.name", "Test"]);
  writeFileSync(path.join(repo, "README.md"), "# scratch\n");
  git(repo, ["add", "-A"]);
  git(repo, ["commit", "-m", "init"]);
  return repo;
}

/** The checkpoint refs git holds under our hidden namespace, sorted. */
function checkpointRefs(repo: string): string[] {
  const out = git(repo, [
    "for-each-ref",
    "--format=%(refname)",
    "refs/agent-deck/checkpoints/",
  ]).trim();
  return out.length === 0 ? [] : out.split("\n").sort();
}

/** A session-file stand-in whose SIZE grows per turn (pi appends per turn), so
 * the capture's mtime/size dedup lets each turn through. */
function makeSessionFile(): { path: string; write: (content: string) => void } {
  const dir = makeTempDir("agent-deck-ckpt-sess-");
  const file = path.join(dir, "session.jsonl");
  return { path: file, write: (content) => writeFileSync(file, content) };
}

function makeService(overrides?: { maxPerSession?: number }): {
  service: CheckpointServiceShape;
  dataDir: string;
} {
  const dataDir = makeTempDir("agent-deck-ckpt-data-");
  return {
    service: makeCheckpointService({ dataDir, ...overrides }),
    dataDir,
  };
}

describe("makeCheckpointService.capture", () => {
  it("captures a checkpoint per turn: hidden git ref whose tree matches the worktree + a session snapshot", async () => {
    const repo = makeRepo();
    const session = makeSessionFile();
    const { service, dataDir } = makeService();
    const sessionId = "sess-A";

    // Turn 1: worktree has out.txt=v1; the session file carries turn 1.
    writeFileSync(path.join(repo, "out.txt"), "v1\n");
    session.write("turn-1\n");
    const c0 = await service.capture({
      sessionId,
      cwd: repo,
      sessionFile: session.path,
      label: "first turn message",
    });

    // Turn 2: worktree out.txt=v2; the session file grows.
    writeFileSync(path.join(repo, "out.txt"), "v2\n");
    session.write("turn-1\nturn-2\n");
    const c1 = await service.capture({
      sessionId,
      cwd: repo,
      sessionFile: session.path,
      label: "second turn message",
    });

    expect(c0).not.toBeNull();
    expect(c1).not.toBeNull();
    expect(c0!.turnIndex).toBe(0);
    expect(c1!.turnIndex).toBe(1);
    expect(c0!.hasFiles).toBe(true);
    expect(c1!.hasFiles).toBe(true);

    // Both hidden refs exist (and are NOT branches).
    expect(checkpointRefs(repo)).toEqual([
      `refs/agent-deck/checkpoints/${sessionId}/0`,
      `refs/agent-deck/checkpoints/${sessionId}/1`,
    ]);
    expect(git(repo, ["branch", "--list"]).trim()).toBe("* main");

    // Each ref's captured tree matches the worktree AT THAT TURN.
    expect(git(repo, ["show", `${c0!.gitRef}:out.txt`])).toBe("v1\n");
    expect(git(repo, ["show", `${c1!.gitRef}:out.txt`])).toBe("v2\n");

    // Each turn snapshotted the session file WHOLESALE (a byte copy).
    expect(existsSync(c0!.sessionSnapshotPath)).toBe(true);
    expect(readFileSync(c0!.sessionSnapshotPath, "utf8")).toBe("turn-1\n");
    expect(readFileSync(c1!.sessionSnapshotPath, "utf8")).toBe("turn-1\nturn-2\n");
    // Snapshots live under <dataDir>/checkpoints/<sessionId>/<n>.session.
    expect(c0!.sessionSnapshotPath).toBe(path.join(dataDir, "checkpoints", sessionId, "0.session"));

    // The metadata index is on-disk JSON (no SQLite).
    const index = JSON.parse(
      readFileSync(path.join(dataDir, "checkpoints", "index.json"), "utf8"),
    ) as Record<string, unknown[]>;
    expect(index[sessionId]).toHaveLength(2);
  });

  it("does NOT disturb the user's index or working tree (staged state preserved)", async () => {
    const repo = makeRepo();
    const session = makeSessionFile();
    const { service } = makeService();

    // Arrange a mixed index: a STAGED new file, a STAGED modification, and an
    // UNSTAGED modification on top — a state capture must leave byte-identical.
    writeFileSync(path.join(repo, "staged-new.txt"), "staged\n");
    git(repo, ["add", "staged-new.txt"]);
    writeFileSync(path.join(repo, "README.md"), "# scratch\nstaged-line\n");
    git(repo, ["add", "README.md"]);
    writeFileSync(path.join(repo, "README.md"), "# scratch\nstaged-line\nunstaged-line\n");
    writeFileSync(path.join(repo, "untracked.txt"), "untracked\n");

    const statusBefore = git(repo, ["status", "--porcelain=v1"]);
    const indexTreeBefore = git(repo, ["write-tree"]).trim();

    session.write("turn-1\n");
    const record = await service.capture({
      sessionId: "sess-B",
      cwd: repo,
      sessionFile: session.path,
      label: "capture over a dirty index",
    });
    expect(record).not.toBeNull();
    expect(record!.hasFiles).toBe(true);

    // The real index (its tree) and the porcelain status are UNCHANGED — the
    // temp-index capture never wrote through .git/index.
    expect(git(repo, ["status", "--porcelain=v1"])).toBe(statusBefore);
    expect(git(repo, ["write-tree"]).trim()).toBe(indexTreeBefore);

    // Yet the checkpoint's tree captured the full worktree (unstaged + untracked).
    expect(git(repo, ["show", `${record!.gitRef}:untracked.txt`])).toBe("untracked\n");
    expect(git(repo, ["show", `${record!.gitRef}:README.md`])).toBe(
      "# scratch\nstaged-line\nunstaged-line\n",
    );
  });

  it("degrades to a conversation-only checkpoint for a non-git cwd (hasFiles=false)", async () => {
    const plainDir = makeTempDir("agent-deck-ckpt-plain-");
    const session = makeSessionFile();
    const { service } = makeService();

    session.write("turn-1\n");
    const record = await service.capture({
      sessionId: "sess-C",
      cwd: plainDir,
      sessionFile: session.path,
      label: "no repo here",
    });
    expect(record).not.toBeNull();
    expect(record!.hasFiles).toBe(false);
    expect(record!.gitRef).toBeNull();
    // The conversation half is still captured.
    expect(existsSync(record!.sessionSnapshotPath)).toBe(true);
    expect(readFileSync(record!.sessionSnapshotPath, "utf8")).toBe("turn-1\n");
  });

  it("skips a duplicate capture when the session file is unchanged (a second idle for the same turn)", async () => {
    const repo = makeRepo();
    const session = makeSessionFile();
    const { service } = makeService();
    const sessionId = "sess-D";

    session.write("turn-1\n");
    const first = await service.capture({
      sessionId,
      cwd: repo,
      sessionFile: session.path,
      label: "t",
    });
    // Same session file (unchanged size+mtime) → no new checkpoint.
    const second = await service.capture({
      sessionId,
      cwd: repo,
      sessionFile: session.path,
      label: "t",
    });

    expect(first).not.toBeNull();
    expect(second).toBeNull();
    expect(await service.records(sessionId)).toHaveLength(1);
    expect(checkpointRefs(repo)).toEqual([`refs/agent-deck/checkpoints/${sessionId}/0`]);
  });

  it("skips when there is no session file yet (conversation half unavailable)", async () => {
    const repo = makeRepo();
    const { service } = makeService();
    const record = await service.capture({
      sessionId: "sess-E",
      cwd: repo,
      sessionFile: undefined,
      label: "no session file",
    });
    expect(record).toBeNull();
    expect(checkpointRefs(repo)).toEqual([]);
  });

  it("caps retained checkpoints, pruning the oldest snapshot file AND its git ref", async () => {
    const repo = makeRepo();
    const session = makeSessionFile();
    const { service } = makeService({ maxPerSession: 2 });
    const sessionId = "sess-F";
    const snapshots: string[] = [];

    for (let turn = 0; turn < 4; turn += 1) {
      writeFileSync(path.join(repo, "out.txt"), `v${turn}\n`);
      session.write("x\n".repeat(turn + 1)); // grow the session file each turn
      const record = await service.capture({
        sessionId,
        cwd: repo,
        sessionFile: session.path,
        label: `turn ${turn}`,
      });
      expect(record).not.toBeNull();
      snapshots.push(record!.sessionSnapshotPath);
    }

    // Only the last 2 checkpoints are retained.
    const records = await service.records(sessionId);
    expect(records.map((r) => r.turnIndex)).toEqual([2, 3]);

    // The pruned snapshot files (turns 0,1) are gone; the kept ones remain.
    expect(existsSync(snapshots[0]!)).toBe(false);
    expect(existsSync(snapshots[1]!)).toBe(false);
    expect(existsSync(snapshots[2]!)).toBe(true);
    expect(existsSync(snapshots[3]!)).toBe(true);

    // The pruned git refs are deleted; only the retained ones survive.
    expect(checkpointRefs(repo)).toEqual([
      `refs/agent-deck/checkpoints/${sessionId}/2`,
      `refs/agent-deck/checkpoints/${sessionId}/3`,
    ]);
  });

  it("list() projects records to the client-facing CheckpointInfo, oldest first", async () => {
    const repo = makeRepo();
    const session = makeSessionFile();
    const { service } = makeService();
    const sessionId = "sess-G";

    writeFileSync(path.join(repo, "out.txt"), "v1\n");
    session.write("a\n");
    await service.capture({
      sessionId,
      cwd: repo,
      sessionFile: session.path,
      label: "  hello world  \nsecond line",
    });
    session.write("a\nb\n");
    await service.capture({ sessionId, cwd: repo, sessionFile: session.path, label: "next" });

    const list = await service.list(sessionId);
    expect(list.map((c) => c.turnIndex)).toEqual([0, 1]);
    // Label is first-lined + trimmed.
    expect(list[0]!.label).toBe("hello world");
    expect(list[0]!.hasFiles).toBe(true);
    // The wire projection carries no server-internal fields.
    expect(Object.keys(list[0]!).sort()).toEqual(["createdAt", "hasFiles", "label", "turnIndex"]);
  });
});
