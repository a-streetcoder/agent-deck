import { execFile } from "node:child_process";
import { rm } from "node:fs/promises";
import { promisify } from "node:util";

/**
 * Git automation (native GitRepositoryService): commit the agent's work in a
 * project's working tree. This is the status + commit-all core; push/remote is a
 * follow-up. Runs the real `git` in the project cwd via execFile (no shell), the
 * same mechanism the gh Issues integration uses. AGENT_DECK_GIT_BIN overrides
 * the binary for tests, matching AGENT_DECK_GH_BIN.
 */

const execFileAsync = promisify(execFile);

export interface GitFileChange {
  /** The 2-char porcelain status (e.g. " M", "??", "A ", "MM"). */
  status: string;
  path: string;
}
export interface GitStatus {
  /** False when the cwd is not inside a git work tree. */
  repo: boolean;
  branch?: string;
  files: GitFileChange[];
  /** True when the work tree has no changes to commit. */
  clean: boolean;
}

function gitBin(): string {
  return process.env.AGENT_DECK_GIT_BIN || "git";
}

async function runGit(cwd: string, args: string[]): Promise<string> {
  const { stdout } = await execFileAsync(gitBin(), args, {
    cwd,
    timeout: 15_000,
    maxBuffer: 8_000_000,
  });
  return stdout;
}

/** Parse `git status --porcelain=v1 --branch` output into a structured status. */
export function parseStatus(stdout: string): { branch?: string; files: GitFileChange[] } {
  let branch: string | undefined;
  const files: GitFileChange[] = [];
  // Split on LF; git emits LF even on Windows for porcelain output.
  for (const line of stdout.split("\n")) {
    if (line === "") continue;
    if (line.startsWith("## ")) {
      const rest = line.slice(3);
      const noCommits = "No commits yet on ";
      if (rest.startsWith(noCommits)) {
        branch = rest.slice(noCommits.length).trim();
      } else if (rest.startsWith("HEAD (no branch)")) {
        branch = undefined; // detached HEAD — no branch to show
      } else {
        // "<branch>...<upstream> [ahead N]" or a bare "<branch>".
        branch = (rest.split("...")[0] ?? rest).split(" ")[0];
      }
      continue;
    }
    // "XY <path>" — exactly two status chars, a space, then the path (verbatim,
    // so paths with spaces survive).
    files.push({ status: line.slice(0, 2), path: line.slice(3) });
  }
  return { branch, files };
}

export async function gitStatus(cwd: string): Promise<GitStatus> {
  let stdout: string;
  try {
    stdout = await runGit(cwd, ["status", "--porcelain=v1", "--branch"]);
  } catch {
    // Not a repo (or git unavailable) — surfaced as repo:false, not an error.
    return { repo: false, files: [], clean: true };
  }
  const { branch, files } = parseStatus(stdout);
  return { repo: true, branch, files, clean: files.length === 0 };
}

/**
 * Stage everything and commit with `message`. Throws "nothing_to_commit" when
 * the work tree is clean (native noChanges) and "not_a_repo" outside a repo, so
 * the route maps them to a 400 with a clear message.
 */
/**
 * Shallow-clone a repository (or a local path — the hermetic test form) into an
 * empty destination dir. GIT_TERMINAL_PROMPT=0 makes a private/auth-required
 * remote fail fast instead of hanging on a credential prompt (native
 * SkillRepositorySyncService). Throws "clone_failed" on any git error.
 */
export async function gitCloneShallow(
  source: string,
  destDir: string,
  ref?: string,
): Promise<void> {
  // A pinned ref (a `/tree/<branch>` URL) clones just that branch.
  const branchArgs = ref ? ["--branch", ref, "--single-branch"] : [];
  try {
    await execFileAsync(gitBin(), ["clone", "--depth", "1", ...branchArgs, source, destDir], {
      timeout: 120_000,
      maxBuffer: 8_000_000,
      env: { ...process.env, GIT_TERMINAL_PROMPT: "0" },
    });
  } catch {
    throw new Error("clone_failed");
  }
}

/**
 * Clone a repo into a PERSISTENT dir kept for later re-sync (native
 * SkillRepositorySyncService.cloneForDiscovery). Uses a blobless partial clone
 * (`--filter=blob:none`) so only reachable trees download up front; if the source
 * rejects the filter (common for a local path), retries a plain clone. `ref`
 * pins the tracked branch. Throws "clone_failed" on failure.
 */
export async function gitClonePersistent(
  source: string,
  destDir: string,
  ref?: string,
): Promise<void> {
  const branchArgs = ref ? ["--branch", ref, "--single-branch"] : [];
  const opts = {
    timeout: 180_000,
    maxBuffer: 8_000_000,
    env: { ...process.env, GIT_TERMINAL_PROMPT: "0" },
  };
  try {
    await execFileAsync(
      gitBin(),
      ["clone", "--filter=blob:none", ...branchArgs, source, destDir],
      opts,
    );
  } catch {
    // Partial-clone filter rejected (e.g. a local source) — retry a plain clone.
    await rm(destDir, { recursive: true, force: true }).catch(() => {});
    try {
      await execFileAsync(gitBin(), ["clone", ...branchArgs, source, destDir], opts);
    } catch {
      throw new Error("clone_failed");
    }
  }
}

/** The HEAD commit sha of a clone (native rev-parse HEAD). */
export async function gitHead(dir: string): Promise<string> {
  return (await runGit(dir, ["rev-parse", "HEAD"])).trim();
}

/**
 * The remote tip sha for `ref` (default HEAD) WITHOUT downloading (native
 * checkForUpdate: `git ls-remote`). Returns null on any error / no match, so a
 * transient network failure just reports "no update known".
 */
export async function gitLsRemote(remoteUrl: string, ref = "HEAD"): Promise<string | null> {
  try {
    const { stdout } = await execFileAsync(gitBin(), ["ls-remote", remoteUrl, ref], {
      timeout: 30_000,
      maxBuffer: 8_000_000,
      env: { ...process.env, GIT_TERMINAL_PROMPT: "0" },
    });
    const sha = stdout.trim().split(/\s+/)[0];
    return sha && /^[0-9a-f]{40}$/.test(sha) ? sha : null;
  } catch {
    return null;
  }
}

/**
 * Fetch the tracked branch and hard-reset the clone to it, returning the new
 * HEAD (native update: fetch + ff). The clone is a read-only mirror (its skills
 * were COPIED into the catalog, never edited in place), so a hard reset can't
 * lose local work. Throws the git error on a fetch/reset failure.
 */
export async function gitPullFfInto(cloneDir: string, ref?: string): Promise<string> {
  // Fetch the SPECIFIC branch (the pinned ref, else the clone's current branch)
  // so FETCH_HEAD is unambiguous — `git fetch origin` with no ref can leave
  // FETCH_HEAD pointing at the wrong branch in a multi-branch clone.
  const branch = ref ?? (await runGit(cloneDir, ["rev-parse", "--abbrev-ref", "HEAD"])).trim();
  await runGit(cloneDir, ["fetch", "origin", branch]);
  await runGit(cloneDir, ["reset", "--hard", "FETCH_HEAD"]);
  return (await runGit(cloneDir, ["rev-parse", "HEAD"])).trim();
}

export async function gitCommitAll(cwd: string, message: string): Promise<{ committed: true }> {
  const status = await gitStatus(cwd);
  if (!status.repo) throw new Error("not_a_repo");
  if (status.clean) throw new Error("nothing_to_commit");
  await runGit(cwd, ["add", "-A"]);
  await runGit(cwd, ["commit", "-m", message]);
  return { committed: true };
}

/**
 * The working-tree status + a diff of all tracked changes vs HEAD, for feeding
 * a commit-message generator (native PiAgentShipService). The diff is capped so
 * a huge change set can't blow the helper model's context. On a fresh repo with
 * no commits (no HEAD), the diff is empty and the status still lists the files.
 */
export async function gitStatusAndDiff(cwd: string): Promise<{ status: string; diff: string }> {
  const status = (await runGit(cwd, ["status", "--porcelain=v1"])).trim();
  let diff = "";
  try {
    diff = (await runGit(cwd, ["diff", "HEAD"])).slice(0, 60_000);
  } catch {
    // No HEAD yet (fresh repo) — the status alone describes the changes.
  }
  return { status, diff };
}

/** The current branch name, or "HEAD" when detached (native readCurrentBranch). */
export async function gitCurrentBranch(cwd: string): Promise<string> {
  return (await runGit(cwd, ["rev-parse", "--abbrev-ref", "HEAD"])).trim();
}

/** True iff `dir` is inside a git working tree (git rev-parse --is-inside-work-tree). */
export async function isGitRepo(dir: string): Promise<boolean> {
  try {
    return (await runGit(dir, ["rev-parse", "--is-inside-work-tree"])).trim() === "true";
  } catch {
    return false; // not a repo, or git unavailable
  }
}

export interface GitWorktree {
  /** The isolated checkout directory. */
  path: string;
  /** The new branch the worktree is on. */
  branch: string;
  /** The branch the worktree was forked from. */
  sourceBranch: string;
}

/**
 * Add a worktree on a NEW branch off sourceBranch (native
 * PiAgentSessionWorktreeService worktree add -b). `targetPath` must not exist —
 * git creates it. Throws "not_a_repo" / a git error on failure.
 */
export async function gitWorktreeAdd(
  projectDir: string,
  targetPath: string,
  branch: string,
  sourceBranch: string,
): Promise<void> {
  await runGit(projectDir, ["worktree", "add", "-b", branch, targetPath, sourceBranch]);
}

/**
 * Remove a worktree directory + prune stale entries (native removeWorktree,
 * without the branch delete — the branch is kept so committed work is never
 * lost). Best-effort: a missing worktree is not an error.
 */
export async function gitWorktreeRemove(projectDir: string, targetPath: string): Promise<void> {
  try {
    await runGit(projectDir, ["worktree", "remove", "--force", targetPath]);
  } catch {
    // Already gone / not a worktree — fall through to prune.
  }
  try {
    await runGit(projectDir, ["worktree", "prune"]);
  } catch {
    // Best-effort.
  }
  // Native removeWorktree also removes the directory if git left it behind — on
  // Windows `git worktree remove` can succeed at the metadata level but leave the
  // dir because the just-exited pi process's handle on its cwd lingers. Use the
  // ASYNC rm (the sync one blocks the event loop during the retries) with a
  // generous retry budget to ride out that EPERM/EBUSY handle-release lag.
  try {
    await rm(targetPath, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 });
  } catch {
    // Best-effort: a leftover dir is harmless (git no longer tracks it).
  }
}

/** Commits on `branch` not yet reachable from `base` (native commitsAhead). */
export async function gitCommitsAhead(cwd: string, branch: string, base: string): Promise<number> {
  const out = (await runGit(cwd, ["rev-list", "--count", `${base}..${branch}`])).trim();
  const n = Number.parseInt(out, 10);
  return Number.isFinite(n) ? n : 0;
}

/**
 * Merge a session's worktree `branch` back into `sourceBranch` (native Merge
 * toolbar action): check out sourceBranch in the project root, then a `--no-ff`
 * merge with an explicit message (no editor). Throws the git stderr on a dirty
 * tree / checkout failure / merge conflict so the caller can surface it. The
 * worktree + branch are left in place (native default keepWorktreeAfterMerge).
 */
export async function gitMerge(
  projectDir: string,
  branch: string,
  sourceBranch: string,
): Promise<void> {
  await runGit(projectDir, ["checkout", sourceBranch]);
  await runGit(projectDir, ["merge", "--no-ff", branch, "-m", `Merge ${branch}`]);
}

/** Propose the next patch/minor/major version off the latest `vX.Y.Z` tag
 *  (semver; native uses a single-digit-minor scheme, generalized here). */
export function nextReleaseVersions(latestTag: string | null): {
  patch: string;
  minor: string;
  major: string;
} {
  const match = latestTag ? /^v(\d+)\.(\d+)\.(\d+)$/.exec(latestTag) : null;
  if (!match) return { patch: "v0.1.0", minor: "v0.1.0", major: "v1.0.0" }; // first release
  const [maj, min, pat] = [Number(match[1]), Number(match[2]), Number(match[3])];
  return {
    patch: `v${maj}.${min}.${pat + 1}`,
    minor: `v${maj}.${min + 1}.0`,
    major: `v${maj + 1}.0.0`,
  };
}

/** Fetch tags from the remote (best-effort; no remote / offline is not fatal). */
export async function gitFetchTags(cwd: string): Promise<void> {
  try {
    await runGit(cwd, ["fetch", "--tags", "--quiet"]);
  } catch {
    // No remote / offline — release preflight still works off local tags.
  }
}

/** The newest `vX.Y.Z` version tag (native latestVersionTag), or null if none. */
export async function gitLatestVersionTag(cwd: string): Promise<string | null> {
  try {
    const out = (
      await runGit(cwd, ["tag", "-l", "v[0-9]*.[0-9]*.[0-9]*", "--sort=-v:refname"])
    ).trim();
    // The glob also matches prerelease tags (v1.2.3-rc), which sort ahead of the
    // plain release — scan for the newest STRICT vX.Y.Z, not just the first line.
    const first = out
      .split("\n")
      .map((line) => line.trim())
      .find((line) => /^v\d+\.\d+\.\d+$/.test(line));
    return first ?? null;
  } catch {
    return null;
  }
}

/** Whether a tag exists locally OR on the remote (so a release can't clobber). */
export async function gitTagExists(cwd: string, tag: string): Promise<boolean> {
  try {
    await runGit(cwd, ["rev-parse", "--verify", "--quiet", `refs/tags/${tag}`]);
    return true;
  } catch {
    try {
      return (await runGit(cwd, ["ls-remote", "--tags", "origin", tag])).trim().length > 0;
    } catch {
      return false; // no remote reachable — the local check already said no
    }
  }
}

/** Commit subjects in `range` (e.g. "v1.2.0..HEAD"), newest first, no merges —
 *  the input to release-notes generation (native commitSubjects). */
export async function gitCommitSubjects(cwd: string, range: string): Promise<string[]> {
  const out = await runGit(cwd, ["log", "--no-merges", "--pretty=format:%s", range]);
  return out
    .split("\n")
    .map((s) => s.trim())
    .filter(Boolean);
}

/**
 * Create an annotated tag with `--cleanup=verbatim` (native createAnnotatedTag) so
 * the message's markdown `#`/`###` lines survive git's default comment-stripping,
 * then push it. Throws the git stderr on failure.
 */
export async function gitTagAndPush(cwd: string, tag: string, message: string): Promise<void> {
  await runGit(cwd, ["tag", "-a", "--cleanup=verbatim", tag, "-m", message || tag]);
  try {
    await runGit(cwd, ["push", "origin", tag]);
  } catch (error) {
    // Release is tag+push as one unit — if the push fails, roll back the local tag
    // so a retry isn't trapped by our own gitTagExists (409) check. Best-effort.
    await runGit(cwd, ["tag", "-d", tag]).catch(() => {});
    throw new Error(`Release failed — couldn't push ${tag}: ${gitErrorText(error)}`);
  }
}

/** The git stderr from a failed execFile, else the error message — for surfacing. */
export function gitErrorText(error: unknown): string {
  const stderr = (error as { stderr?: string }).stderr;
  if (typeof stderr === "string" && stderr.trim()) return stderr.trim();
  return error instanceof Error ? error.message : String(error);
}

/**
 * Push the current branch (native pushCurrentBranch). Try a plain `git push`;
 * if the branch has no upstream (common for a fresh branch), retry with
 * `-u origin <branch>`. Any other failure (no remote, rejected, auth) throws
 * with the git stderr so the caller can surface it.
 */
export async function gitPush(cwd: string): Promise<void> {
  try {
    await runGit(cwd, ["push"]);
    return;
  } catch (firstError) {
    const stderr = String((firstError as { stderr?: string }).stderr ?? "").toLowerCase();
    const missingUpstream =
      stderr.includes("no upstream") ||
      stderr.includes("set-upstream") ||
      stderr.includes("has no upstream");
    if (!missingUpstream) throw new Error(gitErrorText(firstError));
    const branch = (await runGit(cwd, ["rev-parse", "--abbrev-ref", "HEAD"])).trim();
    try {
      await runGit(cwd, ["push", "-u", "origin", branch]);
    } catch (secondError) {
      throw new Error(gitErrorText(secondError));
    }
  }
}
