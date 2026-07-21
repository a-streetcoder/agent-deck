import { chmodSync, mkdirSync, mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { describe, expect, it, vi } from "vitest";
import { EDITORS } from "@agent-deck/contracts";
import {
  buildEditorArgs,
  createEditorLauncher,
  escapeWindowsShellArg,
  resolveCommandPath,
  resolveContainedFile,
  resolveSpawnPlan,
  type SpawnLike,
} from "../src/editorLauncher.ts";

/**
 * Unit tests for the Slice-11 editor launcher: PATH-probe detection against a
 * FAKE PATH (a temp dir of stub executables — no real editor is ever probed),
 * the per-editor launch-argument styles, the containment guard (the security
 * gate: traversal/absolute/symlink-escape paths must never launch), and the
 * spawn seam (an injected spawn recorder asserts the EXACT argv; nothing is
 * ever actually spawned).
 */

const editorDef = (id: string) => {
  const editor = EDITORS.find((entry) => entry.id === id);
  if (!editor) throw new Error(`no such editor in the table: ${id}`);
  return editor;
};

/** A fake PATH dir holding stub CLI files (`.cmd` shims for win32 probing,
 * chmod +x scripts for posix probing — both are plain files on disk). */
function makeFakePathDir(commands: string[]): string {
  const dir = mkdtempSync(nodePath.join(tmpdir(), "editor-path-"));
  for (const command of commands) {
    const file = nodePath.join(dir, command);
    writeFileSync(file, "@echo off\n");
    chmodSync(file, 0o755);
  }
  return dir;
}

function makeSpawnRecorder() {
  const calls: Array<{
    command: string;
    args: readonly string[];
    options: { detached: boolean; stdio: "ignore"; shell: boolean };
  }> = [];
  const unref = vi.fn();
  const errorListeners: Array<(error: Error) => void> = [];
  const on = vi.fn((event: "error", listener: (error: Error) => void) => {
    if (event === "error") errorListeners.push(listener);
  });
  const spawnFn: SpawnLike = (command, args, options) => {
    calls.push({ command, args, options });
    return { unref, on };
  };
  return { spawnFn, calls, unref, on, errorListeners };
}

describe("resolveCommandPath (fake PATH probe)", () => {
  it("win32: resolves a bare command through PATHEXT candidates", () => {
    const dir = makeFakePathDir(["code.cmd"]);
    const env = { PATH: dir, PATHEXT: ".COM;.EXE;.BAT;.CMD" };
    expect(resolveCommandPath("code", env, "win32")).toBe(nodePath.join(dir, "code.cmd"));
    expect(resolveCommandPath("idea", env, "win32")).toBeNull();
  });

  it("posix: resolves an executable file on PATH", () => {
    const dir = makeFakePathDir(["zed"]);
    const env = { PATH: dir };
    expect(resolveCommandPath("zed", env, "linux")).toBe(nodePath.join(dir, "zed"));
    expect(resolveCommandPath("code", env, "linux")).toBeNull();
  });

  it("an empty PATH resolves nothing", () => {
    expect(resolveCommandPath("code", { PATH: "" }, "linux")).toBeNull();
    expect(resolveCommandPath("code", {}, "win32")).toBeNull();
  });
});

describe("detection (listEditors)", () => {
  it("lists exactly the editors whose CLIs are on the fake PATH", async () => {
    const dir = makeFakePathDir(["code.cmd", "webstorm.cmd"]);
    const launcher = createEditorLauncher({
      env: { PATH: dir, PATHEXT: ".CMD" },
      platform: "win32",
    });
    expect(await launcher.listEditors()).toEqual(["vscode", "webstorm"]);
  });

  it("probes alternate command names (zed OR zeditor)", async () => {
    const dir = makeFakePathDir(["zeditor"]);
    const launcher = createEditorLauncher({ env: { PATH: dir }, platform: "linux" });
    expect(await launcher.listEditors()).toEqual(["zed"]);
  });

  it("AGENT_DECK_OPEN_BIN makes every editor available (the e2e seam)", async () => {
    const launcher = createEditorLauncher({
      env: { PATH: "", AGENT_DECK_OPEN_BIN: "/stub/opener" },
      platform: "linux",
    });
    expect(await launcher.listEditors()).toEqual(EDITORS.map((editor) => editor.id));
  });

  it("detects nothing on an empty PATH", async () => {
    const launcher = createEditorLauncher({ env: { PATH: "" }, platform: "linux" });
    expect(await launcher.listEditors()).toEqual([]);
  });
});

describe("buildEditorArgs (per-editor line syntax)", () => {
  const abs = nodePath.join(tmpdir(), "proj", "src", "a.ts");

  it("goto style (VS Code family): --goto path:line", () => {
    expect(buildEditorArgs(editorDef("vscode"), abs, 12)).toEqual(["--goto", `${abs}:12`]);
    expect(buildEditorArgs(editorDef("vscode"), abs, undefined)).toEqual([abs]);
  });

  it("goto style keeps baseArgs first (Kiro's `ide`)", () => {
    expect(buildEditorArgs(editorDef("kiro"), abs, 3)).toEqual(["ide", "--goto", `${abs}:3`]);
    expect(buildEditorArgs(editorDef("kiro"), abs, undefined)).toEqual(["ide", abs]);
  });

  it("line-column style (JetBrains): --line N path", () => {
    expect(buildEditorArgs(editorDef("idea"), abs, 42)).toEqual(["--line", "42", abs]);
    expect(buildEditorArgs(editorDef("webstorm"), abs, undefined)).toEqual([abs]);
  });

  it("direct-path style (Zed): path:line", () => {
    expect(buildEditorArgs(editorDef("zed"), abs, 7)).toEqual([`${abs}:7`]);
    expect(buildEditorArgs(editorDef("zed"), abs, undefined)).toEqual([abs]);
  });
});

describe("resolveContainedFile (the containment gate)", () => {
  function makeRepo(): { cwd: string } {
    const cwd = mkdtempSync(nodePath.join(tmpdir(), "editor-repo-"));
    mkdirSync(nodePath.join(cwd, "src"));
    writeFileSync(nodePath.join(cwd, "src", "a.ts"), "x\n");
    writeFileSync(nodePath.join(nodePath.dirname(cwd), "outside.txt"), "secret\n");
    return { cwd };
  }

  it("resolves a repo-relative path inside the cwd", () => {
    const { cwd } = makeRepo();
    // CANONICAL path expected: the launcher returns realpath (TOCTOU shrink),
    // which differs from the joined path on macOS (/var -> /private/var).
    expect(resolveContainedFile(cwd, "src/a.ts")).toBe(
      realpathSync(nodePath.resolve(cwd, "src", "a.ts")),
    );
  });

  it("rejects .. traversal outside the cwd", () => {
    const { cwd } = makeRepo();
    expect(() => resolveContainedFile(cwd, "../outside.txt")).toThrow(/escapes/);
    expect(() => resolveContainedFile(cwd, "src/../../outside.txt")).toThrow(/escapes/);
  });

  it("rejects absolute client paths outright", () => {
    const { cwd } = makeRepo();
    const abs = nodePath.resolve(cwd, "src", "a.ts");
    expect(() => resolveContainedFile(cwd, abs)).toThrow(/must be relative/);
  });

  it("rejects the cwd itself and missing files", () => {
    const { cwd } = makeRepo();
    expect(() => resolveContainedFile(cwd, ".")).toThrow(/escapes/);
    expect(() => resolveContainedFile(cwd, "src/missing.ts")).toThrow(/not found/);
  });

  it("rejects NUL bytes", () => {
    const { cwd } = makeRepo();
    expect(() => resolveContainedFile(cwd, "src/a.ts\0x")).toThrow(/invalid path/);
  });
});

describe("resolveSpawnPlan (Windows batch-shim shell hop)", () => {
  it("posix: plain command, no shell", () => {
    expect(resolveSpawnPlan("/usr/bin/code", ["--goto", "/p/a.ts:1"], "linux")).toEqual({
      command: "/usr/bin/code",
      args: ["--goto", "/p/a.ts:1"],
      shell: false,
    });
  });

  it("win32 .exe: direct spawn, no shell", () => {
    expect(resolveSpawnPlan("C:\\bin\\zed.exe", ["C:\\p\\a.ts:1"], "win32").shell).toBe(false);
  });

  it("win32 .cmd: shell mode with every argument escaped", () => {
    const plan = resolveSpawnPlan("C:\\bin\\code.cmd", ["--goto", "C:\\p\\a.ts:1"], "win32");
    expect(plan.shell).toBe(true);
    expect(plan.command).toBe(escapeWindowsShellArg("C:\\bin\\code.cmd"));
    expect(plan.args).toEqual([
      escapeWindowsShellArg("--goto"),
      escapeWindowsShellArg("C:\\p\\a.ts:1"),
    ]);
  });

  it("escaping quotes cmd metacharacters and embedded double quotes", () => {
    expect(escapeWindowsShellArg('a"b')).toBe('^"a\\^"b^"');
    // cross-spawn parity: space is in the cmd metachar set, so it carets too.
    expect(escapeWindowsShellArg("a b")).toBe('^"a^ b^"');
  });
});

describe("open (spawn seam — exact argv, no real process)", () => {
  function makeRepo(): { cwd: string; abs: string } {
    const cwd = mkdtempSync(nodePath.join(tmpdir(), "editor-open-"));
    mkdirSync(nodePath.join(cwd, "src"));
    const abs = nodePath.join(cwd, "src", "a.ts");
    writeFileSync(abs, "x\n");
    // CANONICAL path: the launcher spawns on realpath (TOCTOU shrink), which
    // differs from the joined path on macOS (/var -> /private/var symlink).
    return { cwd, abs: realpathSync(nodePath.resolve(abs)) };
  }

  it("launches the AGENT_DECK_OPEN_BIN override with the editor's exact argv", async () => {
    const { cwd, abs } = makeRepo();
    const recorder = makeSpawnRecorder();
    const launcher = createEditorLauncher({
      env: { PATH: "", AGENT_DECK_OPEN_BIN: "/stub/opener" },
      platform: "linux",
      spawnFn: recorder.spawnFn,
    });
    await launcher.open({ cwd, path: "src/a.ts", line: 12, editor: "vscode" });
    expect(recorder.calls).toEqual([
      {
        command: "/stub/opener",
        args: ["--goto", `${abs}:12`],
        options: { detached: true, stdio: "ignore", shell: false },
      },
    ]);
    expect(recorder.unref).toHaveBeenCalledTimes(1);
  });

  it("attaches an 'error' listener so async spawn failures cannot crash the server", async () => {
    const { cwd } = makeRepo();
    const recorder = makeSpawnRecorder();
    const launcher = createEditorLauncher({
      env: { PATH: "", AGENT_DECK_OPEN_BIN: "/stub/opener" },
      platform: "linux",
      spawnFn: recorder.spawnFn,
    });
    await launcher.open({ cwd, path: "src/a.ts", editor: "vscode" });
    expect(recorder.on).toHaveBeenCalledWith("error", expect.any(Function));
    // Emitting the async spawn failure (ENOENT after open() resolved) must be
    // swallowed by the listener, not thrown.
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      expect(recorder.errorListeners.length).toBeGreaterThan(0);
      for (const listener of recorder.errorListeners) {
        expect(() => listener(new Error("spawn /stub/opener ENOENT"))).not.toThrow();
      }
      expect(consoleError).toHaveBeenCalled();
    } finally {
      consoleError.mockRestore();
    }
  });

  it("JetBrains line syntax flows through to the spawn argv", async () => {
    const { cwd, abs } = makeRepo();
    const recorder = makeSpawnRecorder();
    const launcher = createEditorLauncher({
      env: { PATH: "", AGENT_DECK_OPEN_BIN: "/stub/opener" },
      platform: "linux",
      spawnFn: recorder.spawnFn,
    });
    await launcher.open({ cwd, path: "src/a.ts", line: 7, editor: "webstorm" });
    expect(recorder.calls[0]?.args).toEqual(["--line", "7", abs]);
  });

  it("a real PATH resolution spawns the resolved executable", async () => {
    const { cwd, abs } = makeRepo();
    const dir = makeFakePathDir(["zed"]);
    const recorder = makeSpawnRecorder();
    const launcher = createEditorLauncher({
      env: { PATH: dir },
      platform: "linux",
      spawnFn: recorder.spawnFn,
    });
    await launcher.open({ cwd, path: "src/a.ts", editor: "zed" });
    expect(recorder.calls).toEqual([
      {
        command: nodePath.join(dir, "zed"),
        args: [abs],
        options: { detached: true, stdio: "ignore", shell: false },
      },
    ]);
  });

  it("win32 .cmd resolution launches through the shell with escaped argv", async () => {
    const { cwd, abs } = makeRepo();
    const dir = makeFakePathDir(["code.cmd"]);
    const recorder = makeSpawnRecorder();
    const launcher = createEditorLauncher({
      env: { PATH: dir, PATHEXT: ".CMD" },
      platform: "win32",
      spawnFn: recorder.spawnFn,
    });
    await launcher.open({ cwd, path: "src/a.ts", line: 2, editor: "vscode" });
    const call = recorder.calls[0];
    expect(call?.options.shell).toBe(true);
    expect(call?.command).toBe(escapeWindowsShellArg(nodePath.join(dir, "code.cmd")));
    expect(call?.args).toEqual([
      escapeWindowsShellArg("--goto"),
      escapeWindowsShellArg(`${abs}:2`),
    ]);
  });

  it("rejects an editor the server did not detect (never spawns)", async () => {
    const { cwd } = makeRepo();
    const recorder = makeSpawnRecorder();
    const launcher = createEditorLauncher({
      env: { PATH: "" },
      platform: "linux",
      spawnFn: recorder.spawnFn,
    });
    await expect(launcher.open({ cwd, path: "src/a.ts", editor: "vscode" })).rejects.toThrow(
      /unknown editor/,
    );
    expect(recorder.calls).toEqual([]);
  });

  it("rejects traversal before any spawn happens", async () => {
    const { cwd } = makeRepo();
    const recorder = makeSpawnRecorder();
    const launcher = createEditorLauncher({
      env: { PATH: "", AGENT_DECK_OPEN_BIN: "/stub/opener" },
      platform: "linux",
      spawnFn: recorder.spawnFn,
    });
    await expect(launcher.open({ cwd, path: "../outside.txt", editor: "vscode" })).rejects.toThrow(
      /escapes|not found/,
    );
    expect(recorder.calls).toEqual([]);
  });
});
