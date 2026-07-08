import { execFile } from "node:child_process";
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
export async function gitCloneShallow(source: string, destDir: string): Promise<void> {
  try {
    await execFileAsync(gitBin(), ["clone", "--depth", "1", source, destDir], {
      timeout: 120_000,
      maxBuffer: 8_000_000,
      env: { ...process.env, GIT_TERMINAL_PROMPT: "0" },
    });
  } catch {
    throw new Error("clone_failed");
  }
}

export async function gitCommitAll(cwd: string, message: string): Promise<{ committed: true }> {
  const status = await gitStatus(cwd);
  if (!status.repo) throw new Error("not_a_repo");
  if (status.clean) throw new Error("nothing_to_commit");
  await runGit(cwd, ["add", "-A"]);
  await runGit(cwd, ["commit", "-m", message]);
  return { committed: true };
}

/** The current branch name, or "HEAD" when detached (native readCurrentBranch). */
export async function gitCurrentBranch(cwd: string): Promise<string> {
  return (await runGit(cwd, ["rev-parse", "--abbrev-ref", "HEAD"])).trim();
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
}

/** The git stderr from a failed execFile, else the error message — for surfacing. */
function gitErrorText(error: unknown): string {
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
