import { spawn } from "node:child_process";
import { accessSync, constants, statSync } from "node:fs";
import nodePath from "node:path";
import { EDITORS, type EditorId } from "@agent-deck/contracts";
import { resolveContainedPath } from "./pathContainment.ts";

/**
 * Editor detection + launch (Slice 11), ported from t3code's
 * `apps/server/src/process/externalLauncher.ts` + `packages/shared/src/shell.ts`
 * (MIT) and condensed onto this repo's plain-module idiom (git.ts is the
 * template: no Effect service — one-shot probes and detached spawns need no
 * scopes; the rpcHandler consumes the object facade like the other gateways).
 *
 * What survives the port:
 *   - PATH-probe detection: an editor is "available" when one of its CLI
 *     commands resolves to an executable on PATH (win32: PATHEXT candidate
 *     extensions + a real-file stat; posix: X_OK). Editors not installed
 *     simply don't appear. The probe result is CACHED per launcher.
 *   - the per-editor launch-argument styles (`--goto path:line` for the VS
 *     Code family, `--line N path` for JetBrains, `path:line` for Zed).
 *   - the Windows `.cmd`/`.bat` shell hop: Node refuses to spawn batch
 *     shims directly (EINVAL), so those launch through cmd.exe with every
 *     argument escaped via the donor's cross-spawn-style escaping — the
 *     arguments are never interpolated into a shell string unescaped.
 *   - detached, stdio-ignored, unref'd spawn so the server never waits on
 *     (or dies with) an editor process.
 *
 * SECURITY (this slice's gate):
 *   - The op's `path` is repo-RELATIVE and resolved inside the session's cwd;
 *     {@link resolveContainedFile} rejects absolute paths, `..` traversal, and
 *     symlink escapes (realpath containment), and requires the file to exist.
 *     The server never launches a client-supplied absolute path.
 *   - `editor` must be one of the server's OWN detected ids (schema-validated
 *     upstream, membership-checked here) — never a client command string.
 *
 * Test seam: `AGENT_DECK_OPEN_BIN` (the AGENT_DECK_GH_BIN/GIT_BIN precedent)
 * overrides command RESOLUTION wholesale — every editor probes and launches as
 * that binary — so tests and e2e assert the exact argv against a stub instead
 * of spawning a real editor.
 */

export interface EditorOpenInput {
  /** The session's cwd (server-side meta, never the wire). */
  readonly cwd: string;
  /** Repo-relative file path (the diff set's path shape). */
  readonly path: string;
  /** Optional 1-based line to jump to. */
  readonly line?: number;
  readonly editor: EditorId;
}

export interface EditorLauncher {
  /** The editors detected on this machine (probe cached after the first call). */
  readonly listEditors: () => Promise<readonly EditorId[]>;
  /** Open one working-tree file in a detected editor (validates containment). */
  readonly open: (input: EditorOpenInput) => Promise<void>;
}

/** The spawn surface the launcher needs — injectable so unit tests record the
 * exact argv without creating processes. */
export type SpawnLike = (
  command: string,
  args: readonly string[],
  options: { detached: boolean; stdio: "ignore"; shell: boolean },
) => { unref: () => void; on: (event: "error", listener: (error: Error) => void) => unknown };

export interface EditorLauncherOptions {
  /** PATH/PATHEXT (+ AGENT_DECK_OPEN_BIN) source; defaults to process.env. */
  readonly env?: NodeJS.ProcessEnv;
  /** Platform seam (win32 vs posix probing/quoting); defaults to the host's. */
  readonly platform?: NodeJS.Platform;
  /** Launch seam; defaults to node:child_process.spawn. */
  readonly spawnFn?: SpawnLike;
}

type EditorDef = (typeof EDITORS)[number];

// ---------------------------------------------------------------------------
// PATH probing (donor shell.ts `resolveCommandPathForPlatform`, sync'd down)
// ---------------------------------------------------------------------------

const WINDOWS_DEFAULT_PATHEXT = [".COM", ".EXE", ".BAT", ".CMD"];

function windowsPathExtensions(env: NodeJS.ProcessEnv): string[] {
  const raw = env.PATHEXT;
  if (!raw) return WINDOWS_DEFAULT_PATHEXT;
  const parsed = raw
    .split(";")
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0)
    .map((entry) => (entry.startsWith(".") ? entry.toUpperCase() : `.${entry.toUpperCase()}`));
  return parsed.length > 0 ? [...new Set(parsed)] : WINDOWS_DEFAULT_PATHEXT;
}

function readEnvPath(env: NodeJS.ProcessEnv): string {
  return env.PATH ?? env.Path ?? env.path ?? "";
}

function isExecutableFile(
  filePath: string,
  platform: NodeJS.Platform,
  pathExts: readonly string[],
): boolean {
  try {
    if (!statSync(filePath).isFile()) return false;
  } catch {
    return false;
  }
  if (platform === "win32") {
    const extension = nodePath.win32.extname(filePath).toUpperCase();
    return extension.length > 0 && pathExts.includes(extension);
  }
  try {
    accessSync(filePath, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/**
 * Resolve a bare CLI command name to its executable on PATH, or null. On
 * win32 each PATH entry is probed with every PATHEXT candidate (`code` →
 * `code.cmd`…); elsewhere the bare name is probed for X_OK.
 */
export function resolveCommandPath(
  command: string,
  env: NodeJS.ProcessEnv,
  platform: NodeJS.Platform = process.platform,
): string | null {
  const pathExts = platform === "win32" ? windowsPathExtensions(env) : [];
  const candidates =
    platform === "win32" ? pathExts.map((ext) => `${command}${ext.toLowerCase()}`) : [command];
  // HOST delimiter, not the simulated platform's: the PATH string always
  // comes from the HOST process env (splitting `C:\…` entries on ":" would
  // shear off drive letters when tests simulate posix probing on Windows).
  for (const rawEntry of readEnvPath(env).split(nodePath.delimiter)) {
    const entry = rawEntry.trim().replace(/^"+|"+$/g, "");
    if (entry.length === 0) continue;
    for (const candidate of candidates) {
      // HOST-native join: the PATH entries are host paths (in tests the fake
      // PATH dir is host-native too, whatever `platform` simulates).
      const candidatePath = nodePath.join(entry, candidate);
      if (isExecutableFile(candidatePath, platform, pathExts)) return candidatePath;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Launch-argument styles (donor externalLauncher.ts `resolveEditorArgs`)
// ---------------------------------------------------------------------------

/** The target arguments for one editor, per its launch style (pure; tested). */
export function buildEditorArgs(
  editor: EditorDef,
  absPath: string,
  line: number | undefined,
): string[] {
  const baseArgs = "baseArgs" in editor ? [...editor.baseArgs] : [];
  switch (editor.launchStyle) {
    case "direct-path":
      return [...baseArgs, line !== undefined ? `${absPath}:${line}` : absPath];
    case "goto":
      return [...baseArgs, ...(line !== undefined ? ["--goto", `${absPath}:${line}`] : [absPath])];
    case "line-column":
      return [...baseArgs, ...(line !== undefined ? ["--line", String(line)] : []), absPath];
  }
}

// ---------------------------------------------------------------------------
// Path containment (the slice's security gate)
// ---------------------------------------------------------------------------

/**
 * Resolve a repo-relative path against the session cwd, rejecting anything
 * that escapes it: absolute inputs, `..` traversal, and symlinks pointing
 * outside (realpath containment — the resolved REAL path must stay under the
 * cwd's real path). The file must exist (a deleted changed-set entry can't be
 * opened). Returns the absolute CANONICAL path to hand to the editor (launching
 * on realpath shrinks the check-to-spawn TOCTOU window; defense-in-depth).
 *
 * A thin wrapper over the shared {@link resolveContainedPath} gate (Slice 13a
 * lifted the logic there so the file-navigation endpoints reuse it verbatim);
 * `allowBase` stays false — opening the cwd directory itself is meaningless.
 */
export function resolveContainedFile(cwd: string, relativePath: string): string {
  return resolveContainedPath(cwd, relativePath);
}

// ---------------------------------------------------------------------------
// Windows .cmd/.bat shell hop (donor shell.ts `resolveSpawnCommand`)
// ---------------------------------------------------------------------------

const WINDOWS_SHELL_META_CHARS = /([()\][%!^"`<>&|;, *?])/g;

/**
 * Escape one argument for `spawn(..., { shell: true })` on Windows (cmd.exe):
 * quote-escape for CommandLineToArgvW, then caret-escape cmd metacharacters.
 * Mirrors cross-spawn's escaping (the donor's `escapeWindowsShellArg`).
 */
export function escapeWindowsShellArg(arg: string): string {
  let escaped = arg.replace(/(\\*)"/g, '$1$1\\"');
  escaped = escaped.replace(/(\\*)$/, "$1$1");
  escaped = `"${escaped}"`;
  return escaped.replace(WINDOWS_SHELL_META_CHARS, "^$1");
}

/** The spawn plan: batch shims hop through the shell with escaped argv. */
export function resolveSpawnPlan(
  resolvedCommand: string,
  args: readonly string[],
  platform: NodeJS.Platform,
): { command: string; args: string[]; shell: boolean } {
  if (platform !== "win32") return { command: resolvedCommand, args: [...args], shell: false };
  const extension = nodePath.win32.extname(resolvedCommand).toLowerCase();
  if (extension !== ".cmd" && extension !== ".bat") {
    return { command: resolvedCommand, args: [...args], shell: false };
  }
  return {
    command: escapeWindowsShellArg(resolvedCommand),
    args: args.map(escapeWindowsShellArg),
    shell: true,
  };
}

// ---------------------------------------------------------------------------
// The launcher facade
// ---------------------------------------------------------------------------

export function createEditorLauncher(options: EditorLauncherOptions = {}): EditorLauncher {
  const platform = options.platform ?? process.platform;
  const spawnFn: SpawnLike =
    options.spawnFn ?? ((command, args, spawnOptions) => spawn(command, [...args], spawnOptions));
  const env = (): NodeJS.ProcessEnv => options.env ?? process.env;
  const openBin = (): string | undefined => {
    const value = env().AGENT_DECK_OPEN_BIN;
    return value && value.length > 0 ? value : undefined;
  };

  /** First resolvable CLI for an editor (or the seam override), else null. */
  const resolveEditorCommand = (editor: EditorDef): string | null => {
    const override = openBin();
    if (override !== undefined) return override;
    for (const command of editor.commands) {
      const resolved = resolveCommandPath(command, env(), platform);
      if (resolved !== null) return resolved;
    }
    return null;
  };

  // Donor parity: t3code re-probes on every resolveAvailableEditors() call —
  // no cache at any donor layer — so an editor installed while the server runs
  // appears on the next list. The probe walks PATH × PATHEXT per editor
  // command; list calls are rare (picker open), so re-probing is fine.
  const listEditors = (): Promise<readonly EditorId[]> =>
    Promise.resolve().then(() =>
      EDITORS.filter((editor) => resolveEditorCommand(editor) !== null).map((editor) => editor.id),
    );

  const open = async (input: EditorOpenInput): Promise<void> => {
    const available = await listEditors();
    if (!available.includes(input.editor)) {
      throw new Error(`unknown editor: ${input.editor}`);
    }
    const editor = EDITORS.find((entry) => entry.id === input.editor);
    if (!editor) throw new Error(`unknown editor: ${input.editor}`);
    const absPath = resolveContainedFile(input.cwd, input.path);
    const command = resolveEditorCommand(editor);
    if (command === null) throw new Error(`editor command not found: ${input.editor}`);
    const plan = resolveSpawnPlan(command, buildEditorArgs(editor, absPath, input.line), platform);
    const child = spawnFn(plan.command, plan.args, {
      detached: true,
      stdio: "ignore",
      shell: plan.shell,
    });
    // Spawn failures (ENOENT/EACCES) are emitted asynchronously on the child
    // as an 'error' EVENT, after open() has already resolved — with no
    // listener, Node throws it as an uncaught exception and kills the whole
    // server. Fire-and-forget launches log and move on instead.
    child.on("error", (error) => {
      console.error(`[editor] launch failed for ${input.editor}:`, error);
    });
    child.unref();
  };

  return { listEditors, open };
}
