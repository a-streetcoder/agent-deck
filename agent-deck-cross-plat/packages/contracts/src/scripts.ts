import { Schema } from "effect";

/**
 * Project-script + dev-server-preview wire contract (Slice 15a) — run a
 * session project's DECLARED scripts as managed child processes, stream their
 * output, and report the loopback dev-server URL they start listening on.
 *
 * Ported from t3code's `apps/server/src/{preview,project,environment}/` (MIT)
 * and re-expressed in this package's idioms — the terminal.ts pattern exactly:
 * requests ride `RpcClientFrame`, replies/pushes get their own frame kinds so
 * `ClientMessage`/`ServerMessage` stay parity-pinned against the legacy
 * envelope. A running script is the sibling of a terminal PTY: server-allocated
 * id (`run-N`), scope-owned lifecycle, bounded output chunks, capped scrollback
 * replayed on reattach.
 *
 * Design deltas from the donor, deliberate for our smaller op surface:
 *   - The donor runs setup scripts by WRITING the command into a terminal PTY
 *     and discovers ports with a background `lsof`/`Get-NetTCPConnection` poll
 *     mapped to the terminal's process tree. We instead spawn each script as a
 *     dedicated MANAGED child process (the terminal.ts scoped template) so its
 *     output and lifecycle are attributable to exactly that run, and detect the
 *     port from the run's OWN stdout (a loopback URL match) confirmed by a
 *     loopback TCP probe — so a reported server is always this run's, never an
 *     unrelated process already bound to a common dev port.
 *   - Run ids are SERVER-allocated (`script_start`/`script_attach` →
 *     `script_run_ok` carries the id back); the client never supplies a command
 *     string — only a `scriptName` the server resolves against the project's
 *     declared `package.json` scripts (the security boundary).
 *   - `cwd` never rides the wire: a run belongs to a SESSION and the server
 *     spawns it in that session's cwd (worktree-aware `meta.cwd`).
 *
 * SECURITY: the only host ever reported is `localhost`. A candidate port is
 * extracted from the run's stdout only when the printed host is a recognized
 * loopback token, then confirmed by connecting to `127.0.0.1:port`; the URL put
 * on the wire is always normalized to `http://localhost:port`. A script cannot
 * trick the UI into embedding an arbitrary external origin.
 */

/** Upper bound for one `script_output` push chunk; the server splits larger reads. */
export const SCRIPT_MAX_OUTPUT_CHUNK = 65_536;
/**
 * Cap (in characters) of the server-side scrollback buffer, and therefore of
 * the `scrollback` field replayed by `script_run_ok` on reattach.
 */
export const SCRIPT_MAX_SCROLLBACK_CHARS = 262_144;
/** Cap on the number of scripts listed for a project (defense-in-depth). */
export const SCRIPT_MAX_SCRIPTS = 500;
/** Upper bound for a script name (npm's package/script name ceiling). */
export const SCRIPT_NAME_MAX = 214;
/** Upper bound for a declared script's command string. */
export const SCRIPT_COMMAND_MAX = 16_384;

/** Integer with `Number.isInteger` semantics (`WireInt` parity — see protocol.ts). */
const wireInt = (description: string) =>
  Schema.Number.pipe(
    Schema.filter((n) => Number.isInteger(n) || "must be an integer", {
      identifier: "ScriptWireInt",
      description,
    }),
  );

/** Server-allocated run id (`run-N`), bounded like the terminal id (max 128). */
export const ScriptRunId = Schema.String.pipe(Schema.minLength(1), Schema.maxLength(128));
export type ScriptRunId = typeof ScriptRunId.Type;

/** A declared script name (a `package.json` `scripts` key). */
export const ScriptName = Schema.String.pipe(
  Schema.minLength(1),
  Schema.maxLength(SCRIPT_NAME_MAX),
);
export type ScriptName = typeof ScriptName.Type;

/** One runnable script declared in the session project's `package.json`. */
export const ProjectScript = Schema.Struct({
  name: ScriptName,
  /** The command as declared (shown to the user; never client-supplied on run). */
  command: Schema.String.pipe(Schema.maxLength(SCRIPT_COMMAND_MAX)),
});
export type ProjectScript = typeof ProjectScript.Type;

/**
 * A discovered dev server. `host` is ALWAYS `localhost` (loopback-only — see
 * module doc); `url` is the normalized `http://localhost:port`.
 */
export const DiscoveredServer = Schema.Struct({
  host: Schema.Literal("localhost"),
  port: wireInt("dev server port").pipe(
    Schema.greaterThanOrEqualTo(1),
    Schema.lessThanOrEqualTo(65_535),
  ),
  url: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(2_048)),
});
export type DiscoveredServer = typeof DiscoveredServer.Type;

// ---------------------------------------------------------------------------
// Client → server script requests (ride RpcClientFrame alongside ClientMessage)
// ---------------------------------------------------------------------------

export const ScriptClientRequest = Schema.Union(
  Schema.Struct({
    /** List the session project's declared scripts (from `package.json`). */
    type: Schema.Literal("scripts_list"),
    sessionId: Schema.String,
  }),
  Schema.Struct({
    /**
     * Start one DECLARED script as a managed child process. The server resolves
     * `scriptName` against the project's `package.json` scripts and spawns its
     * command in the session cwd — the client never supplies a command string.
     */
    type: Schema.Literal("script_start"),
    sessionId: Schema.String,
    scriptName: ScriptName,
  }),
  Schema.Struct({
    /**
     * Reattach to a run this connection already started: the reply replays its
     * scrollback + reports the current server, and the push listener is replaced.
     */
    type: Schema.Literal("script_attach"),
    runId: ScriptRunId,
  }),
  Schema.Struct({
    /** Stop a run: tree-kill the child process (idempotent). */
    type: Schema.Literal("script_stop"),
    runId: ScriptRunId,
  }),
);
export type ScriptClientRequest = typeof ScriptClientRequest.Type;

// ---------------------------------------------------------------------------
// Server → client script pushes (ride the `script_push` frame)
// ---------------------------------------------------------------------------

export const ScriptPush = Schema.Union(
  Schema.Struct({
    type: Schema.Literal("script_output"),
    runId: ScriptRunId,
    /** One output chunk (merged stdout+stderr); the server splits larger reads. */
    data: Schema.String.pipe(Schema.maxLength(SCRIPT_MAX_OUTPUT_CHUNK)),
  }),
  Schema.Struct({
    /** The run's dev server was detected + confirmed listening on loopback. */
    type: Schema.Literal("script_server"),
    runId: ScriptRunId,
    server: DiscoveredServer,
  }),
  Schema.Struct({
    type: Schema.Literal("script_exit"),
    runId: ScriptRunId,
    exitCode: Schema.NullOr(wireInt("script exit code")),
    /** The POSIX signal name that killed the child (null when exited normally). */
    signal: Schema.NullOr(Schema.String.pipe(Schema.maxLength(32))),
  }),
);
export type ScriptPush = typeof ScriptPush.Type;
