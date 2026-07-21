import { Schema } from "effect";
import { DiffPath } from "./diff.ts";

/**
 * Open-in-editor wire contract (Slice 11) — list the editors detected on the
 * SERVER's machine and open one changed file (at a line where the editor's CLI
 * supports it) in one of them. Shaped from t3code's `packages/contracts/src/
 * editor.ts` + `apps/server/src/process/externalLauncher.ts` (MIT): the same
 * editor table (id / label / CLI commands / launch style), the same three
 * launch-argument styles, re-expressed in this package's idioms (requests ride
 * `RpcClientFrame`; the list reply gets its own frame kind — see rpc.ts).
 *
 * Differences vs the donor, deliberate:
 *   - The donor opens a WORKSPACE (`cwd`) in the editor; our surface opens a
 *     FILE from the Slice-10 diff panel / changed-files tree, so the op takes
 *     a repo-relative `path` (+ optional 1-based `line`) and the server
 *     resolves it INSIDE the session's cwd (the containment guard lives
 *     server-side in editorLauncher.ts — the wire never carries an absolute
 *     path).
 *   - The donor's `file-manager` pseudo-editor (open the cwd in Finder/
 *     Explorer) is omitted: it has no meaning for a file-at-line target.
 *
 * SECURITY: `editor` is an id into this table — the server maps it to its OWN
 * detected command; a client can never supply a command string. `path` is
 * validated server-side to stay within the session's cwd.
 */

/**
 * How an editor's CLI expresses "open this file at this line":
 *   - `direct-path`: `cmd path:line` (Zed).
 *   - `goto`: `cmd --goto path:line` (the VS Code family).
 *   - `line-column`: `cmd --line N path` (the JetBrains family).
 */
export const EditorLaunchStyle = Schema.Literal("direct-path", "goto", "line-column");
export type EditorLaunchStyle = typeof EditorLaunchStyle.Type;

interface EditorDefinition {
  readonly id: string;
  readonly label: string;
  /** CLI candidates probed on PATH, in preference order. */
  readonly commands: readonly [string, ...string[]];
  /** Arguments always prepended before the target (e.g. Kiro's `ide`). */
  readonly baseArgs?: readonly string[];
  readonly launchStyle: EditorLaunchStyle;
}

/** The editor table (donor's EDITORS, minus `file-manager` — see above). */
export const EDITORS = [
  { id: "cursor", label: "Cursor", commands: ["cursor"], launchStyle: "goto" },
  { id: "trae", label: "Trae", commands: ["trae"], launchStyle: "goto" },
  { id: "kiro", label: "Kiro", commands: ["kiro"], baseArgs: ["ide"], launchStyle: "goto" },
  { id: "vscode", label: "VS Code", commands: ["code"], launchStyle: "goto" },
  {
    id: "vscode-insiders",
    label: "VS Code Insiders",
    commands: ["code-insiders"],
    launchStyle: "goto",
  },
  { id: "vscodium", label: "VSCodium", commands: ["codium"], launchStyle: "goto" },
  { id: "zed", label: "Zed", commands: ["zed", "zeditor"], launchStyle: "direct-path" },
  { id: "antigravity", label: "Antigravity", commands: ["agy"], launchStyle: "goto" },
  { id: "idea", label: "IntelliJ IDEA", commands: ["idea"], launchStyle: "line-column" },
  { id: "aqua", label: "Aqua", commands: ["aqua"], launchStyle: "line-column" },
  { id: "clion", label: "CLion", commands: ["clion"], launchStyle: "line-column" },
  { id: "datagrip", label: "DataGrip", commands: ["datagrip"], launchStyle: "line-column" },
  { id: "dataspell", label: "DataSpell", commands: ["dataspell"], launchStyle: "line-column" },
  { id: "goland", label: "GoLand", commands: ["goland"], launchStyle: "line-column" },
  { id: "phpstorm", label: "PhpStorm", commands: ["phpstorm"], launchStyle: "line-column" },
  { id: "pycharm", label: "PyCharm", commands: ["pycharm"], launchStyle: "line-column" },
  { id: "rider", label: "Rider", commands: ["rider"], launchStyle: "line-column" },
  { id: "rubymine", label: "RubyMine", commands: ["rubymine"], launchStyle: "line-column" },
  { id: "rustrover", label: "RustRover", commands: ["rustrover"], launchStyle: "line-column" },
  { id: "webstorm", label: "WebStorm", commands: ["webstorm"], launchStyle: "line-column" },
] as const satisfies readonly EditorDefinition[];

export const EditorId = Schema.Literal(...EDITORS.map((editor) => editor.id));
export type EditorId = typeof EditorId.Type;

/** A 1-based line number. Safe-integer + sane max: `Number.isInteger(1e300)`
 * is true and stringifies as "1e+300", which would reach editor argv as a
 * nonsense --line value — bound it like WireInt intends. */
const EDITOR_LINE_MAX = 10_000_000;
const EditorLine = Schema.Number.pipe(
  Schema.filter(
    (n) =>
      (Number.isSafeInteger(n) && n >= 1 && n <= EDITOR_LINE_MAX) ||
      "must be a positive integer within bounds",
    {
      identifier: "EditorLine",
      description: "a 1-based line number",
    },
  ),
);

// ---------------------------------------------------------------------------
// Client → server editor requests (ride RpcClientFrame alongside ClientMessage)
// ---------------------------------------------------------------------------

export const EditorClientRequest = Schema.Union(
  Schema.Struct({
    /** List the editors detected on the server's machine (probe is cached). */
    type: Schema.Literal("editors_list"),
  }),
  Schema.Struct({
    /** Open one file of the session's working tree in a detected editor. */
    type: Schema.Literal("editor_open"),
    sessionId: Schema.String,
    /** Repo-relative (the diff set's path shape); resolved INSIDE the
     * session's cwd server-side — traversal outside it is rejected. */
    path: DiffPath,
    /** Optional 1-based line to jump to (where the editor CLI supports it). */
    line: Schema.optional(EditorLine),
    /** Must be one of the server's DETECTED editors, or the op fails. */
    editor: EditorId,
  }),
);
export type EditorClientRequest = typeof EditorClientRequest.Type;
