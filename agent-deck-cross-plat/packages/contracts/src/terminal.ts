import { Schema } from "effect";

/**
 * Terminal wire contract (Slice 8a) — the per-session integrated terminal,
 * ported from t3code's `packages/contracts/src/terminal.ts` (MIT) and
 * re-expressed in this package's idioms (effect 3.22 `Schema.Struct` unions
 * discriminated by `type`, `WireInt`-style integer filters).
 *
 * Design deltas from the donor, deliberate for our smaller op surface:
 *   - Terminal ids are SERVER-allocated (`terminal_open` → `terminal_open_ok`
 *     carries the id back); the donor's client-chosen `term-N` convention
 *     shifts to the reply because our RPC framing already correlates replies.
 *   - `cwd` never rides the wire: a terminal belongs to a SESSION and the
 *     server spawns it in that session's cwd (worktree-aware `meta.cwd`).
 *   - Scrollback rides the `terminal_open_ok` reply (bounded), replacing the
 *     donor's separate attach-stream snapshot event.
 *
 * Every size constraint is explicit: input and output chunks are bounded, and
 * the scrollback buffer replayed on reattach is capped at the same limit the
 * server enforces (`TERMINAL_MAX_SCROLLBACK_CHARS`).
 */

/** Upper bound for one `terminal_input` keystroke/paste chunk (donor: 64 KiB). */
export const TERMINAL_MAX_INPUT_CHUNK = 65_536;
/** Upper bound for one `terminal_output` push chunk; the server splits larger PTY reads. */
export const TERMINAL_MAX_OUTPUT_CHUNK = 65_536;
/**
 * Cap (in characters) of the server-side scrollback buffer, and therefore of
 * the `scrollback` field replayed by `terminal_open_ok` on reattach.
 */
export const TERMINAL_MAX_SCROLLBACK_CHARS = 262_144;

/** Integer with `Number.isInteger` semantics (`WireInt` parity — see protocol.ts). */
const wireInt = (description: string) =>
  Schema.Number.pipe(
    Schema.filter((n) => Number.isInteger(n) || "must be an integer", {
      identifier: "TerminalWireInt",
      description,
    }),
  );

/** PTY width in columns (donor bounds: 1..1000). */
export const TerminalCols = wireInt("terminal columns").pipe(
  Schema.greaterThanOrEqualTo(1),
  Schema.lessThanOrEqualTo(1_000),
);
export type TerminalCols = typeof TerminalCols.Type;

/** PTY height in rows (donor bounds: 1..500). */
export const TerminalRows = wireInt("terminal rows").pipe(
  Schema.greaterThanOrEqualTo(1),
  Schema.lessThanOrEqualTo(500),
);
export type TerminalRows = typeof TerminalRows.Type;

/** Server-allocated terminal id (`term-N`), bounded like the donor's (max 128). */
export const TerminalId = Schema.String.pipe(Schema.minLength(1), Schema.maxLength(128));
export type TerminalId = typeof TerminalId.Type;

// ---------------------------------------------------------------------------
// Client → server terminal requests (ride RpcClientFrame alongside ClientMessage)
// ---------------------------------------------------------------------------

export const TerminalClientRequest = Schema.Union(
  Schema.Struct({
    type: Schema.Literal("terminal_open"),
    /** The owning session; the PTY spawns in this session's cwd, server-side. */
    sessionId: Schema.String,
    /**
     * Omitted: open a NEW terminal (the server allocates the id). Present:
     * reattach to a terminal this connection already opened — the reply
     * replays its scrollback and the push listener is replaced.
     */
    terminalId: Schema.optional(TerminalId),
    cols: Schema.optional(TerminalCols),
    rows: Schema.optional(TerminalRows),
  }),
  Schema.Struct({
    type: Schema.Literal("terminal_input"),
    terminalId: TerminalId,
    /** Raw bytes for the PTY (keystrokes/paste), bounded per chunk. */
    data: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(TERMINAL_MAX_INPUT_CHUNK)),
  }),
  Schema.Struct({
    type: Schema.Literal("terminal_resize"),
    terminalId: TerminalId,
    cols: TerminalCols,
    rows: TerminalRows,
  }),
  Schema.Struct({
    type: Schema.Literal("terminal_close"),
    terminalId: TerminalId,
  }),
);
export type TerminalClientRequest = typeof TerminalClientRequest.Type;

// ---------------------------------------------------------------------------
// Server → client terminal pushes (ride the `terminal_push` frame)
// ---------------------------------------------------------------------------

export const TerminalPush = Schema.Union(
  Schema.Struct({
    type: Schema.Literal("terminal_output"),
    terminalId: TerminalId,
    /** One PTY output chunk; the server splits reads above the bound. */
    data: Schema.String.pipe(Schema.maxLength(TERMINAL_MAX_OUTPUT_CHUNK)),
  }),
  Schema.Struct({
    type: Schema.Literal("terminal_exit"),
    terminalId: TerminalId,
    exitCode: Schema.NullOr(wireInt("terminal exit code")),
    /** Numeric signal per node-pty's `IExitEvent` (null when exited normally). */
    signal: Schema.NullOr(wireInt("terminal exit signal")),
  }),
);
export type TerminalPush = typeof TerminalPush.Type;
