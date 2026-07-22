import { Schema } from "effect";
import {
  DIFF_MAX_PATCH_CHARS,
  DiffClientRequest,
  DiffFileEntry,
  DiffPath,
  DiffPush,
} from "./diff.ts";
import { EditorClientRequest, EditorId } from "./editor.ts";
import {
  FILE_CONTENT_MAX_CHARS,
  FILE_LIST_MAX_ENTRIES,
  FileClientRequest,
  FileContentKind,
  FileDirPath,
  FileListEntry,
} from "./files.ts";
import { ClientMessage, ServerMessage, SessionMeta } from "./protocol.ts";
import {
  DiscoveredServer,
  ProjectScript,
  SCRIPT_MAX_SCRIPTS,
  SCRIPT_MAX_SCROLLBACK_CHARS,
  ScriptClientRequest,
  ScriptPush,
  ScriptRunId,
} from "./scripts.ts";
import {
  TERMINAL_MAX_SCROLLBACK_CHARS,
  TerminalClientRequest,
  TerminalId,
  TerminalPush,
} from "./terminal.ts";

/**
 * The Effect-RPC-over-WebSocket wire framing (Slice 7).
 *
 * This is the same operation surface as the legacy `ws` envelope
 * (`ClientMessage`/`ServerMessage`), but wrapped in a request/response +
 * server-push protocol so the client can correlate replies to the command that
 * produced them. It lives ALONGSIDE the legacy envelope — the legacy `/ws` path
 * still speaks bare `ClientMessage`/`ServerMessage`; the new `/rpc` path speaks
 * these frames. Effect Schema is the runtime validator on BOTH ends of `/rpc`
 * (the server decodes `RpcClientFrame`, the client decodes `RpcServerFrame`).
 *
 * We are on `effect` 3.22, which predates `effect/unstable/rpc`; this is the
 * RpcGroup pattern hand-rolled to that idiom (a typed operation table +
 * id-correlated replies + a push stream), not a wholesale lift of t3code's
 * effect-4 `RpcServer`/`RpcClient`. The bytes on the wire are our pi domain
 * events, not t3code's provider events.
 *
 * Frame kinds
 * -----------
 * client → server: `RpcClientFrame` = `{ id, request: ClientMessage }`.
 *   `id` is a per-connection, monotonically increasing request id.
 *
 * server → client: `RpcServerFrame`, a union discriminated by `kind`:
 *   - `reply`    — an ack (`ok: true`) or a typed failure (`ok: false, error`)
 *                  for the request with the matching `id`.
 *   - `hello_ok` — the reply to a `hello` request, carrying the session list.
 *   - `push`     — an UNSOLICITED server→client message (the stamped domain
 *                  event stream + snapshots + meta/removed/resources/exit),
 *                  carrying no `id`. `message` is a bare {@link ServerMessage},
 *                  so seq/replay/snapshot semantics are byte-identical to legacy.
 */

/**
 * The request id: a non-negative integer. Uses `Number.isInteger` (not
 * `isSafeInteger`) to match the `WireInt` semantics elsewhere in the contract.
 */
const RequestId = Schema.Number.pipe(
  Schema.filter((n) => (Number.isInteger(n) && n >= 0) || "must be a non-negative integer", {
    identifier: "RpcRequestId",
    description: "a non-negative integer request id",
  }),
);

/**
 * client → server: a request frame carrying one legacy client command or —
 * since Slice 8a — one terminal request (terminal.ts), or — since Slice 9 —
 * one diff request (diff.ts), or — since Slice 11 — one editor request
 * (editor.ts). `ClientMessage` itself is untouched: it stays parity-pinned
 * against the legacy zod envelope, so the terminal/diff/editor surfaces widen
 * the FRAME, not the legacy message union.
 */
export const RpcClientFrame = Schema.Struct({
  id: RequestId,
  request: Schema.Union(
    ClientMessage,
    TerminalClientRequest,
    DiffClientRequest,
    EditorClientRequest,
    FileClientRequest,
    ScriptClientRequest,
  ),
});
export type RpcClientFrame = typeof RpcClientFrame.Type;

/** server → client: an id-correlated ack (`ok:true`) or failure (`ok:false`). */
export const RpcReplyFrame = Schema.Union(
  Schema.Struct({ kind: Schema.Literal("reply"), id: RequestId, ok: Schema.Literal(true) }),
  Schema.Struct({
    kind: Schema.Literal("reply"),
    id: RequestId,
    ok: Schema.Literal(false),
    error: Schema.String,
  }),
);
export type RpcReplyFrame = typeof RpcReplyFrame.Type;

/** server → client: the reply to a `hello` request, carrying the session list. */
export const RpcHelloOkFrame = Schema.Struct({
  kind: Schema.Literal("hello_ok"),
  id: RequestId,
  sessions: Schema.mutable(Schema.Array(SessionMeta)),
});
export type RpcHelloOkFrame = typeof RpcHelloOkFrame.Type;

/**
 * server → client: an unsolicited push. `message` is a bare `ServerMessage`
 * (the same push subset the legacy envelope broadcasts / streams per
 * subscription: event, snapshot, session_exit, session_meta, session_removed,
 * resources_changed), so the seq/replay/snapshot contract is unchanged.
 */
export const RpcPushFrame = Schema.Struct({
  kind: Schema.Literal("push"),
  message: ServerMessage,
});
export type RpcPushFrame = typeof RpcPushFrame.Type;

/**
 * server → client: the reply to a `terminal_open` request (Slice 8a). Carries
 * the server-allocated terminal id, plus — on reattach — the bounded scrollback
 * buffer and whether the PTY is still running (an exited terminal replays its
 * scrollback but will push no further output).
 */
export const RpcTerminalOpenOkFrame = Schema.Struct({
  kind: Schema.Literal("terminal_open_ok"),
  id: RequestId,
  terminalId: TerminalId,
  scrollback: Schema.String.pipe(Schema.maxLength(TERMINAL_MAX_SCROLLBACK_CHARS)),
  running: Schema.Boolean,
});
export type RpcTerminalOpenOkFrame = typeof RpcTerminalOpenOkFrame.Type;

/**
 * server → client: an unsolicited terminal push (Slice 8a) — output chunks and
 * the exit notification. A separate frame kind from `push` so `ServerMessage`
 * (parity-pinned against the legacy envelope) stays untouched.
 */
export const RpcTerminalPushFrame = Schema.Struct({
  kind: Schema.Literal("terminal_push"),
  message: TerminalPush,
});
export type RpcTerminalPushFrame = typeof RpcTerminalPushFrame.Type;

/**
 * server → client: the reply to a `diff_files` request (Slice 9) — the
 * session's changed-file set. `repo: false` (with an empty set) is the clean
 * non-git-session answer; it is never an error.
 */
export const RpcDiffFilesOkFrame = Schema.Struct({
  kind: Schema.Literal("diff_files_ok"),
  id: RequestId,
  repo: Schema.Boolean,
  files: Schema.Array(DiffFileEntry),
  /** True when the set was capped (see diff.ts DIFF_MAX_FILES). */
  truncated: Schema.Boolean,
});
export type RpcDiffFilesOkFrame = typeof RpcDiffFilesOkFrame.Type;

/**
 * server → client: the reply to a `diff_file` request (Slice 9) — one file's
 * unified diff, capped with an explicit truncation flag. A path that is not in
 * the session's changed-file set (or a binary file) answers with an empty
 * diff, never an error.
 */
export const RpcDiffFileOkFrame = Schema.Struct({
  kind: Schema.Literal("diff_file_ok"),
  id: RequestId,
  path: DiffPath,
  diff: Schema.String.pipe(Schema.maxLength(DIFF_MAX_PATCH_CHARS)),
  truncated: Schema.Boolean,
  binary: Schema.Boolean,
});
export type RpcDiffFileOkFrame = typeof RpcDiffFileOkFrame.Type;

/**
 * server → client: an unsolicited diff push (Slice 9) — a session's
 * changed-file set was refreshed at a turn boundary and differs from the
 * previous set. A separate frame kind from `push` so `ServerMessage`
 * (parity-pinned against the legacy envelope) stays untouched, exactly like
 * `terminal_push`.
 */
export const RpcDiffPushFrame = Schema.Struct({
  kind: Schema.Literal("diff_push"),
  message: DiffPush,
});
export type RpcDiffPushFrame = typeof RpcDiffPushFrame.Type;

/**
 * server → client: the reply to an `editors_list` request (Slice 11) — the
 * editors DETECTED on the server's machine (its own probe; editors not
 * installed simply don't appear). `editor_open` answers with a plain `reply`.
 */
export const RpcEditorsOkFrame = Schema.Struct({
  kind: Schema.Literal("editors_ok"),
  id: RequestId,
  editors: Schema.Array(EditorId),
});
export type RpcEditorsOkFrame = typeof RpcEditorsOkFrame.Type;

/**
 * server → client: the reply to a `file_list` request (Slice 13a) — one
 * directory's entries within the session's project, bounded (see files.ts
 * FILE_LIST_MAX_ENTRIES). `path` is the listed directory relative to the
 * project root ("" for the root itself).
 */
export const RpcFileListOkFrame = Schema.Struct({
  kind: Schema.Literal("file_list_ok"),
  id: RequestId,
  path: FileDirPath,
  // Decode-side cap (defense-in-depth, parity with DiffPush's maxItems): the
  // producer already slices to FILE_LIST_MAX_ENTRIES, so a conforming frame
  // never exceeds it; a non-conforming/compromised producer is rejected here.
  entries: Schema.Array(FileListEntry).pipe(Schema.maxItems(FILE_LIST_MAX_ENTRIES)),
  /** True when the listing was capped at FILE_LIST_MAX_ENTRIES entries. */
  truncated: Schema.Boolean,
});
export type RpcFileListOkFrame = typeof RpcFileListOkFrame.Type;

/**
 * server → client: the reply to a `file_read` request (Slice 13a) — one file's
 * bounded content. `contentKind` discriminates delivery: `text` (UTF-8, capped
 * with `truncated`), `image` (`content` is a `data:` URI), or `binary`
 * (`content` empty). `byteLength` is the file's true size on disk.
 */
export const RpcFileReadOkFrame = Schema.Struct({
  kind: Schema.Literal("file_read_ok"),
  id: RequestId,
  path: DiffPath,
  contentKind: FileContentKind,
  content: Schema.String.pipe(Schema.maxLength(FILE_CONTENT_MAX_CHARS)),
  byteLength: Schema.Number.pipe(
    Schema.filter((n) => (Number.isInteger(n) && n >= 0) || "must be a non-negative integer", {
      identifier: "FileByteLength",
      description: "the file's size in bytes",
    }),
  ),
  /** True when a text file was capped at FILE_READ_MAX_BYTES. */
  truncated: Schema.Boolean,
});
export type RpcFileReadOkFrame = typeof RpcFileReadOkFrame.Type;

/**
 * server → client: the reply to a `scripts_list` request (Slice 15a) — the
 * session project's declared `package.json` scripts. An empty array is the
 * clean "no package.json / no scripts" answer; it is never an error.
 */
export const RpcScriptsListOkFrame = Schema.Struct({
  kind: Schema.Literal("scripts_list_ok"),
  id: RequestId,
  // Decode-side cap (defense-in-depth, parity with DiffPush's maxItems): the
  // producer already slices to SCRIPT_MAX_SCRIPTS.
  scripts: Schema.Array(ProjectScript).pipe(Schema.maxItems(SCRIPT_MAX_SCRIPTS)),
});
export type RpcScriptsListOkFrame = typeof RpcScriptsListOkFrame.Type;

/**
 * server → client: the reply to a `script_start` / `script_attach` request
 * (Slice 15a). Carries the server-allocated run id, the bounded scrollback
 * (populated on reattach), whether the child is still running, and the current
 * discovered dev server (present once detected+confirmed, so a reattaching
 * preview can re-embed without waiting for the next push).
 */
export const RpcScriptRunOkFrame = Schema.Struct({
  kind: Schema.Literal("script_run_ok"),
  id: RequestId,
  runId: ScriptRunId,
  scrollback: Schema.String.pipe(Schema.maxLength(SCRIPT_MAX_SCROLLBACK_CHARS)),
  running: Schema.Boolean,
  server: Schema.NullOr(DiscoveredServer),
});
export type RpcScriptRunOkFrame = typeof RpcScriptRunOkFrame.Type;

/**
 * server → client: an unsolicited script push (Slice 15a) — output chunks, the
 * discovered-server notification, and the exit notification. A separate frame
 * kind from `push` so `ServerMessage` (parity-pinned) stays untouched, exactly
 * like `terminal_push` / `diff_push`.
 */
export const RpcScriptPushFrame = Schema.Struct({
  kind: Schema.Literal("script_push"),
  message: ScriptPush,
});
export type RpcScriptPushFrame = typeof RpcScriptPushFrame.Type;

/** server → client: the full frame union spoken on the `/rpc` path. */
export const RpcServerFrame = Schema.Union(
  RpcReplyFrame,
  RpcHelloOkFrame,
  RpcPushFrame,
  RpcTerminalOpenOkFrame,
  RpcTerminalPushFrame,
  RpcDiffFilesOkFrame,
  RpcDiffFileOkFrame,
  RpcDiffPushFrame,
  RpcEditorsOkFrame,
  RpcFileListOkFrame,
  RpcFileReadOkFrame,
  RpcScriptsListOkFrame,
  RpcScriptRunOkFrame,
  RpcScriptPushFrame,
);
export type RpcServerFrame = typeof RpcServerFrame.Type;

/** The WebSocket path the RPC endpoint listens on (legacy stays on `/ws`). */
export const RPC_WS_PATH = "/rpc";
