import { Schema } from "effect";
import { ClientMessage, ServerMessage, SessionMeta } from "./protocol.ts";
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
 * since Slice 8a — one terminal request (terminal.ts). `ClientMessage` itself
 * is untouched: it stays parity-pinned against the legacy zod envelope, so the
 * terminal surface widens the FRAME, not the legacy message union.
 */
export const RpcClientFrame = Schema.Struct({
  id: RequestId,
  request: Schema.Union(ClientMessage, TerminalClientRequest),
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

/** server → client: the full frame union spoken on the `/rpc` path. */
export const RpcServerFrame = Schema.Union(
  RpcReplyFrame,
  RpcHelloOkFrame,
  RpcPushFrame,
  RpcTerminalOpenOkFrame,
  RpcTerminalPushFrame,
);
export type RpcServerFrame = typeof RpcServerFrame.Type;

/** The WebSocket path the RPC endpoint listens on (legacy stays on `/ws`). */
export const RPC_WS_PATH = "/rpc";
