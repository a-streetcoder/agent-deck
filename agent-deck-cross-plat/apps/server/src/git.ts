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
