import {
  RpcClientFrame,
  type DiffPush,
  type RpcServerFrame,
  type ServerMessage,
} from "@agent-deck/contracts";
import { Either, Schema } from "effect";
import { WebSocketServer, type WebSocket } from "ws";
import type { CheckpointRollbackGateway } from "./checkpointRollback.ts";
import type { DiffGateway } from "./diffGateway.ts";
import type { EditorLauncher } from "./editorLauncher.ts";
import type { OpenedScript, ScriptRunnerGateway } from "./scriptRunnerGateway.ts";
import type { ManagedSession, SessionManager } from "./SessionManager.ts";
import type { CheckpointServiceShape } from "./services/checkpoints.ts";
import type { FileService } from "./services/files.ts";
import type { ScriptEvent } from "./services/scriptRunner.ts";
import type { TerminalEvent } from "./services/terminal.ts";
import type { OpenedTerminal, TerminalGateway } from "./terminalGateway.ts";

/**
 * The Effect-RPC-over-WebSocket endpoint (Slice 7), mounted on `/rpc` by
 * wsHandler.ts as the sole socket transport (the legacy `/ws` envelope was
 * retired in Slice 7c). It shares the `SessionManager` facade — which resolves
 * the pi subprocess + push bus through the server's ManagedRuntime (runtime.ts
 * services: sessionManager, pushBus) — and reuses the same seq/replay/snapshot
 * primitives (`session.bus.subscribe` / `session.bus.replayFrom` /
 * `session.snapshot()`) that the transport has always exposed; only the framing
 * is RPC.
 *
 * Wire (see @agent-deck/contracts `rpc.ts`):
 *   - client → server: `RpcClientFrame` = `{ id, request: ClientMessage }`,
 *     decoded (and thus runtime-VALIDATED) here through the contracts Effect
 *     Schema — this is where contracts is the runtime validator.
 *   - server → client: `RpcServerFrame` union — an id-correlated `reply` /
 *     `hello_ok`, or an unsolicited `push` wrapping a bare `ServerMessage`.
 *
 * The per-connection protocol lives in {@link createRpcConnection}, decoupled
 * from `ws` so it is unit-testable with a plain `send` collector.
 */

const decodeClientFrame = Schema.decodeUnknownEither(RpcClientFrame);

// Terminal push backpressure (Slice 8 hardening): a PTY is a sustained
// multi-MB/s producer (`yes`, `cat largefile`), and `ws` buffers frames in
// server memory without bound when the client is slow. When the socket's send
// buffer crosses the high-water mark we PAUSE the producing PTY (node-pty
// pause/resume) and poll for drain — ws exposes no drain event — resuming
// below the low-water mark. Session/pi pushes are low-rate and stay ungated.
/** Pause a terminal's PTY once the socket buffers more than this (bytes). */
export const TERMINAL_PUSH_PAUSE_BUFFERED_BYTES = 1_048_576;
/** Resume paused PTYs once the socket buffer drains below this (bytes). */
export const TERMINAL_PUSH_RESUME_BUFFERED_BYTES = 131_072;
/** Drain poll cadence while at least one PTY is paused. */
export const TERMINAL_PUSH_DRAIN_POLL_MS = 50;

/** One RPC connection's protocol: message dispatch + subscription cleanup,
 * independent of the socket transport. */
export interface RpcConnection {
  /** Dispatch one raw client frame (JSON text). Resolves after any async op. */
  handleMessage: (raw: string) => Promise<void>;
  /** Release every per-session subscription this connection holds. */
  close: () => void;
}

export function createRpcConnection(deps: {
  sessions: SessionManager;
  terminals: TerminalGateway;
  diffs: DiffGateway;
  editors: EditorLauncher;
  files: FileService;
  scripts: ScriptRunnerGateway;
  checkpoints: CheckpointServiceShape;
  rollback: CheckpointRollbackGateway;
  send: (frame: RpcServerFrame) => void;
  /** Socket send-buffer depth in bytes (`ws` bufferedAmount); 0 when absent. */
  bufferedAmount?: () => number;
}): RpcConnection {
  const { sessions, terminals, diffs, editors, files, scripts, checkpoints, rollback, send } = deps;
  const bufferedAmount = deps.bufferedAmount ?? ((): number => 0);
  const push = (message: ServerMessage): void => send({ kind: "push", message });

  // Per-connection subscription bookkeeping: re-subscribing to a session
  // replaces its old subscription, and every listener is released on close.
  const cleanups = new Map<string, () => void>();
  // Set by close(); guards async handlers (terminal_open's awaited spawn) from
  // registering resources into maps close() has already swept.
  let connectionClosed = false;

  // Terminal ownership (Slice 8a): terminals opened over THIS connection, each
  // one a detached Scope owned via its gateway handle. Every teardown path —
  // terminal_close, the connection dropping, the owning session exiting —
  // funnels into `entry.opened.close()` (the scope close that kills the PTY).
  interface TerminalEntry {
    opened: OpenedTerminal;
    /** Unsubscribe of the CURRENT push listener (replaced on reattach). */
    detach: () => void;
  }
  const terminalEntries = new Map<string, TerminalEntry>();

  // Script-run ownership (Slice 15a): dev-server/script runs started over THIS
  // connection, each a detached Scope owned via its gateway handle. Same
  // teardown funnel as terminals — script_stop, connection drop, owning-session
  // exit — all reach `entry.opened.close()` (the scope close that tree-kills the
  // child), so no orphan dev servers.
  interface ScriptEntry {
    opened: OpenedScript;
    /** Unsubscribe of the CURRENT push listener (replaced on reattach). */
    detach: () => void;
  }
  const scriptEntries = new Map<string, ScriptEntry>();

  // One session-exit hook per session with live terminals/runs: the session
  // closing (pi exit — destroy() funnels into stop() → exit) tears its
  // terminals AND script runs down, so a removed session can never leave orphan
  // child processes.
  const sessionExitHooks = new Map<string, () => void>();

  // Backpressure valve state: PTYs paused because this connection's socket
  // buffer crossed the high-water mark, and the drain poller that resumes them.
  const pausedTerminals = new Set<OpenedTerminal>();
  let drainPoll: ReturnType<typeof setInterval> | null = null;
  const stopDrainPoll = (): void => {
    if (drainPoll !== null) {
      clearInterval(drainPoll);
      drainPoll = null;
    }
  };
  const resumePausedTerminals = (): void => {
    for (const opened of pausedTerminals) opened.resume();
    pausedTerminals.clear();
    stopDrainPoll();
  };
  const ensureDrainPoll = (): void => {
    if (drainPoll !== null) return;
    drainPoll = setInterval(() => {
      if (bufferedAmount() <= TERMINAL_PUSH_RESUME_BUFFERED_BYTES) resumePausedTerminals();
    }, TERMINAL_PUSH_DRAIN_POLL_MS);
    // Never keep the process alive just to poll a socket buffer (unref is
    // absent under fake timers in tests, hence the feature check).
    (drainPoll as { unref?: () => void }).unref?.();
  };

  const terminalListener =
    (terminalId: string, opened: OpenedTerminal) =>
    (event: TerminalEvent): void => {
      if (event._tag === "Output") {
        send({
          kind: "terminal_push",
          message: { type: "terminal_output", terminalId, data: event.data },
        });
        // The frame just queued may have tipped the socket buffer over the
        // high-water mark: pause THIS producer until the buffer drains.
        if (!pausedTerminals.has(opened) && bufferedAmount() > TERMINAL_PUSH_PAUSE_BUFFERED_BYTES) {
          opened.pause();
          pausedTerminals.add(opened);
          ensureDrainPoll();
        }
        return;
      }
      send({
        kind: "terminal_push",
        message: {
          type: "terminal_exit",
          terminalId,
          exitCode: event.exit.exitCode,
          signal: event.exit.signal,
        },
      });
    };

  const closeTerminal = (terminalId: string): void => {
    const entry = terminalEntries.get(terminalId);
    if (!entry) return;
    terminalEntries.delete(terminalId);
    pausedTerminals.delete(entry.opened);
    if (pausedTerminals.size === 0) stopDrainPoll();
    // The push listener stays attached through the close so the client still
    // receives the terminal_exit push produced by the PTY kill.
    void entry.opened.close().catch(() => {});
  };

  const scriptListener =
    (runId: string) =>
    (event: ScriptEvent): void => {
      if (event._tag === "Output") {
        send({ kind: "script_push", message: { type: "script_output", runId, data: event.data } });
        return;
      }
      if (event._tag === "Server") {
        send({
          kind: "script_push",
          message: { type: "script_server", runId, server: event.server },
        });
        return;
      }
      send({
        kind: "script_push",
        message: {
          type: "script_exit",
          runId,
          exitCode: event.exit.exitCode,
          signal: event.exit.signal,
        },
      });
    };

  const closeScript = (runId: string): void => {
    const entry = scriptEntries.get(runId);
    if (!entry) return;
    scriptEntries.delete(runId);
    // The push listener stays attached through the close so the client still
    // receives the script_exit push produced by the tree-kill.
    void entry.opened.close().catch(() => {});
  };

  const closeSessionProcesses = (sessionId: string): void => {
    for (const [terminalId, entry] of terminalEntries) {
      if (entry.opened.sessionId === sessionId) closeTerminal(terminalId);
    }
    for (const [runId, entry] of scriptEntries) {
      if (entry.opened.sessionId === sessionId) closeScript(runId);
    }
    sessionExitHooks.get(sessionId)?.();
    sessionExitHooks.delete(sessionId);
  };

  const ensureSessionExitHook = (session: ManagedSession): void => {
    const sessionId = session.meta.id;
    if (sessionExitHooks.has(sessionId)) return;
    // onExit fires the listener SYNCHRONOUSLY when the session has already
    // exited (services/sessionManager.ts) — possible when the session dies
    // between the handler's sessions.get() and the child spawn. Detect that and
    // drop the hook instead of storing a stale no-op unhook for a session
    // that will never fire again.
    let exited = false;
    const unhook = session.onExit(() => {
      exited = true;
      closeSessionProcesses(sessionId);
    });
    if (exited) {
      unhook();
      return;
    }
    sessionExitHooks.set(sessionId, unhook);
  };

  const subscribe = (session: ManagedSession, lastSeq?: number): void => {
    cleanups.get(session.meta.id)?.();

    const unsubscribeBus = session.bus.subscribe(({ seq, event }) => {
      push({ type: "event", sessionId: session.meta.id, seq, event });
    });
    const unsubscribeExit = session.onExit((exit) =>
      push({
        type: "session_exit",
        sessionId: session.meta.id,
        code: exit.code,
        signal: exit.signal,
      }),
    );
    cleanups.set(session.meta.id, () => {
      unsubscribeBus();
      unsubscribeExit();
    });

    // seq/replay/snapshot semantics: subscribe with lastSeq → replay from the
    // ring, or snapshot when the ring has evicted that seq.
    if (lastSeq !== undefined) {
      const replay = session.bus.replayFrom(lastSeq);
      if (replay) {
        for (const { seq, event } of replay) {
          push({ type: "event", sessionId: session.meta.id, seq, event });
        }
        return;
      }
    }
    const { seq, state } = session.snapshot();
    push({ type: "snapshot", sessionId: session.meta.id, seq, state });
  };

  const handleMessage = async (raw: string): Promise<void> => {
    // Best-effort id extraction so a decode failure can still be correlated to
    // the request that produced it.
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      send({ kind: "reply", id: 0, ok: false, error: "invalid JSON" });
      return;
    }
    const rawId =
      typeof parsed === "object" &&
      parsed !== null &&
      typeof (parsed as { id?: unknown }).id === "number"
        ? (parsed as { id: number }).id
        : 0;
    const id = Number.isInteger(rawId) && rawId >= 0 ? rawId : 0;

    const decoded = decodeClientFrame(parsed);
    if (Either.isLeft(decoded)) {
      send({ kind: "reply", id, ok: false, error: "invalid message" });
      return;
    }
    const { request } = decoded.right;
    const replyOk = (): void => send({ kind: "reply", id, ok: true });
    const replyError = (message: string): void =>
      send({ kind: "reply", id, ok: false, error: message });

    if (request.type === "hello") {
      send({ kind: "hello_ok", id, sessions: sessions.list() });
      return;
    }

    // Terminal ops (Slice 8a) — handled ahead of the session dispatch because
    // input/resize/close address a terminalId, not a sessionId.
    if (request.type === "terminal_open") {
      const session = sessions.get(request.sessionId);
      if (!session) {
        replyError("unknown session");
        return;
      }
      if (request.terminalId !== undefined) {
        // Reattach: replace the push listener and replay the scrollback.
        const entry = terminalEntries.get(request.terminalId);
        if (!entry || entry.opened.sessionId !== request.sessionId) {
          replyError("unknown terminal");
          return;
        }
        entry.detach();
        const attachment = entry.opened.attach(terminalListener(request.terminalId, entry.opened));
        entry.detach = attachment.unsubscribe;
        send({
          kind: "terminal_open_ok",
          id,
          terminalId: request.terminalId,
          scrollback: attachment.scrollback,
          running: attachment.running,
        });
        return;
      }
      // An ENDED session stays listed (only destroy removes it) but its exit
      // hook would reap any fresh terminal synchronously — reject instead of
      // burning a shell spawn+kill and reporting `running: true`.
      if (session.meta.endedAt !== undefined) {
        replyError("session has ended");
        return;
      }
      try {
        // cwd comes from the session, server-side (worktree-aware meta.cwd).
        const opened = await terminals.open({
          sessionId: session.meta.id,
          cwd: session.meta.cwd,
          cols: request.cols,
          rows: request.rows,
        });
        // The socket may have dropped DURING the spawn — close() already swept
        // (and cleared) terminalEntries, so inserting now would orphan this
        // PTY forever. Reap it immediately instead.
        if (connectionClosed) {
          void opened.close().catch(() => {});
          return;
        }
        const attachment = opened.attach(terminalListener(opened.terminalId, opened));
        terminalEntries.set(opened.terminalId, { opened, detach: attachment.unsubscribe });
        ensureSessionExitHook(session);
        // The session may have exited DURING the spawn: the hook fired
        // immediately and already reaped the entry — report the truth instead
        // of a running terminal that is being killed.
        if (!terminalEntries.has(opened.terminalId)) {
          replyError("session has ended");
          return;
        }
        send({
          kind: "terminal_open_ok",
          id,
          terminalId: opened.terminalId,
          scrollback: attachment.scrollback,
          running: attachment.running,
        });
      } catch (error) {
        replyError(String(error));
      }
      return;
    }
    if (
      request.type === "terminal_input" ||
      request.type === "terminal_resize" ||
      request.type === "terminal_close"
    ) {
      const entry = terminalEntries.get(request.terminalId);
      if (!entry) {
        replyError("unknown terminal");
        return;
      }
      try {
        switch (request.type) {
          case "terminal_input":
            await entry.opened.write(request.data);
            break;
          case "terminal_resize":
            await entry.opened.resize(request.cols, request.rows);
            break;
          case "terminal_close":
            closeTerminal(request.terminalId);
            break;
        }
        replyOk();
      } catch (error) {
        replyError(String(error));
      }
      return;
    }
    // Diff ops (Slice 9) — session-ownership validated like the terminal ops
    // (the cwd is resolved server-side from the session's meta, never the wire).
    if (request.type === "diff_files" || request.type === "diff_file") {
      const session = sessions.get(request.sessionId);
      if (!session) {
        replyError("unknown session");
        return;
      }
      try {
        if (request.type === "diff_files") {
          const set = await diffs.listFiles(session.meta.id, session.meta.cwd);
          send({
            kind: "diff_files_ok",
            id,
            repo: set.repo,
            files: set.files,
            truncated: set.truncated,
          });
        } else {
          const result = await diffs.fileDiff(session.meta.id, session.meta.cwd, request.path);
          send({
            kind: "diff_file_ok",
            id,
            path: request.path,
            diff: result.diff,
            truncated: result.truncated,
            binary: result.binary,
          });
        }
      } catch (error) {
        replyError(String(error));
      }
      return;
    }
    // Editor ops (Slice 11). editors_list is machine-scoped (no session);
    // editor_open resolves the file INSIDE the session's cwd (server-side
    // meta, like the diff ops) and only launches server-DETECTED editor ids —
    // the containment + membership validation lives in editorLauncher.ts.
    if (request.type === "editors_list") {
      try {
        send({ kind: "editors_ok", id, editors: await editors.listEditors() });
      } catch (error) {
        replyError(String(error));
      }
      return;
    }
    if (request.type === "editor_open") {
      const session = sessions.get(request.sessionId);
      if (!session) {
        replyError("unknown session");
        return;
      }
      try {
        await editors.open({
          cwd: session.meta.cwd,
          path: request.path,
          ...(request.line !== undefined ? { line: request.line } : {}),
          editor: request.editor,
        });
        replyOk();
      } catch (error) {
        replyError(error instanceof Error ? error.message : String(error));
      }
      return;
    }
    // File-navigation ops (Slice 13a) — session-ownership validated like the
    // diff/editor ops; the cwd is resolved server-side from the session's meta
    // (worktree-aware) and the path stays within it (containment in
    // services/files.ts, the SAME gate editorLauncher uses).
    if (
      request.type === "file_list" ||
      request.type === "file_read" ||
      request.type === "file_write"
    ) {
      const session = sessions.get(request.sessionId);
      if (!session) {
        replyError("unknown session");
        return;
      }
      try {
        if (request.type === "file_list") {
          const result = await files.listDirectory(session.meta.cwd, request.path);
          send({
            kind: "file_list_ok",
            id,
            path: result.path,
            entries: result.entries,
            truncated: result.truncated,
          });
        } else if (request.type === "file_read") {
          const result = await files.readFile(session.meta.cwd, request.path);
          send({
            kind: "file_read_ok",
            id,
            path: request.path,
            contentKind: result.contentKind,
            content: result.content,
            byteLength: result.byteLength,
            truncated: result.truncated,
            version: result.version,
          });
        } else {
          // file_write (Slice L4b): overwrite an existing file atomically, with
          // the on-disk version conflict guard. cwd is server-side meta; the
          // path stays within it (same containment gate as read).
          const result = await files.writeFile(
            session.meta.cwd,
            request.path,
            request.content,
            request.baseVersion,
          );
          send({
            kind: "file_write_ok",
            id,
            path: request.path,
            outcome: result.outcome,
            version: result.version,
          });
        }
      } catch (error) {
        replyError(error instanceof Error ? error.message : String(error));
      }
      return;
    }
    // Script/dev-server ops (Slice 15a). scripts_list + script_start address a
    // session (cwd resolved server-side from meta, never the wire; the command
    // resolved from the project's package.json, never client-supplied);
    // script_attach + script_stop address a runId this connection owns.
    if (request.type === "scripts_list") {
      const session = sessions.get(request.sessionId);
      if (!session) {
        replyError("unknown session");
        return;
      }
      try {
        const list = await scripts.listScripts(session.meta.cwd);
        send({ kind: "scripts_list_ok", id, scripts: list });
      } catch (error) {
        replyError(error instanceof Error ? error.message : String(error));
      }
      return;
    }
    if (request.type === "script_start") {
      const session = sessions.get(request.sessionId);
      if (!session) {
        replyError("unknown session");
        return;
      }
      // An ENDED session stays listed but its exit hook would reap a fresh run
      // synchronously — reject instead of burning a spawn+kill.
      if (session.meta.endedAt !== undefined) {
        replyError("session has ended");
        return;
      }
      try {
        const opened = await scripts.start({
          sessionId: session.meta.id,
          scriptName: request.scriptName,
          cwd: session.meta.cwd,
        });
        // The socket may have dropped DURING the spawn — close() already swept
        // scriptEntries, so inserting now would orphan the child. Reap it.
        if (connectionClosed) {
          void opened.close().catch(() => {});
          return;
        }
        const attachment = opened.attach(scriptListener(opened.runId));
        scriptEntries.set(opened.runId, { opened, detach: attachment.unsubscribe });
        ensureSessionExitHook(session);
        // The session may have exited DURING the spawn: the hook fired and
        // already reaped the entry — report the truth, not a running run.
        if (!scriptEntries.has(opened.runId)) {
          replyError("session has ended");
          return;
        }
        send({
          kind: "script_run_ok",
          id,
          runId: opened.runId,
          scrollback: attachment.scrollback,
          running: attachment.running,
          server: attachment.server,
        });
      } catch (error) {
        replyError(error instanceof Error ? error.message : String(error));
      }
      return;
    }
    if (request.type === "script_attach") {
      const entry = scriptEntries.get(request.runId);
      if (!entry) {
        replyError("unknown run");
        return;
      }
      entry.detach();
      const attachment = entry.opened.attach(scriptListener(request.runId));
      entry.detach = attachment.unsubscribe;
      send({
        kind: "script_run_ok",
        id,
        runId: request.runId,
        scrollback: attachment.scrollback,
        running: attachment.running,
        server: attachment.server,
      });
      return;
    }
    if (request.type === "script_stop") {
      const entry = scriptEntries.get(request.runId);
      if (!entry) {
        replyError("unknown run");
        return;
      }
      closeScript(request.runId);
      replyOk();
      return;
    }
    // Checkpoint ops (Slice 18a) — session-ownership validated like the diff/
    // file ops. Read-only here (capture happens server-side at the idle
    // boundary); the cwd is never taken from the wire — checkpoint records carry
    // their own captured cwd.
    if (request.type === "checkpoints_list") {
      const session = sessions.get(request.sessionId);
      if (!session) {
        replyError("unknown session");
        return;
      }
      try {
        const list = await checkpoints.list(session.meta.id);
        send({ kind: "checkpoints_list_ok", id, checkpoints: list });
      } catch (error) {
        replyError(error instanceof Error ? error.message : String(error));
      }
      return;
    }
    // Checkpoint rollback (Slice 18b) — DESTRUCTIVE: restore both halves of a
    // prior turn + relaunch pi. The client confirms first (a destructive-confirm
    // dialog); the cwd + snapshot come from the captured record, never the wire.
    if (request.type === "checkpoint_rollback") {
      const session = sessions.get(request.sessionId);
      if (!session) {
        replyError("unknown session");
        return;
      }
      const sessionId = session.meta.id;
      // Release THIS connection's subscription BEFORE the rollback stops pi, so
      // the old session's pi-exit doesn't push a spurious `session_exit` error
      // to this client mid-rollback. The fresh subscription below re-attaches to
      // the relaunched session and pushes the restored transcript.
      cleanups.get(sessionId)?.();
      cleanups.delete(sessionId);
      try {
        const result = await rollback.rollback({ sessionId, turnIndex: request.turnIndex });
        // Re-subscribe to the RELAUNCHED session: subscribe() pushes a fresh
        // snapshot of the restored transcript (seq restarts on the new bus, so
        // the stale client lastSeq falls back to a snapshot, which resets it).
        const relaunched = sessions.get(sessionId);
        if (relaunched) subscribe(relaunched);
        send({ kind: "checkpoint_rollback_ok", id, filesRestored: result.filesRestored });
      } catch (error) {
        replyError(error instanceof Error ? error.message : String(error));
      }
      return;
    }
    const session = sessions.get(request.sessionId);
    if (!session) {
      replyError("unknown session");
      return;
    }
    try {
      switch (request.type) {
        case "subscribe_session":
          subscribe(session, request.lastSeq);
          break;
        case "prompt":
          await session.prompt(request.message, request.images);
          break;
        case "steer":
          await session.steer(request.message);
          break;
        case "follow_up":
          await session.followUp(request.message);
          break;
        case "abort":
          await session.abort();
          break;
        case "compact":
          await session.compact();
          break;
        case "set_model": {
          // Only switch to models pi actually offers.
          const available = await session.getAvailableModels();
          const known = available.some(
            (m) => m.provider === request.provider && m.id === request.modelId,
          );
          if (!known) {
            replyError(`unknown model: ${request.provider}/${request.modelId}`);
            return;
          }
          await session.setModel(request.provider, request.modelId);
          break;
        }
        case "set_thinking":
          await session.setThinkingLevel(request.level);
          break;
        case "ui_response":
          session.respondToUiRequest(request.response);
          break;
      }
      replyOk();
    } catch (error) {
      replyError(String(error));
    }
  };

  return {
    handleMessage,
    close: () => {
      connectionClosed = true;
      for (const cleanup of cleanups.values()) cleanup();
      cleanups.clear();
      // The terminals are dying anyway; stop the drain poller outright.
      stopDrainPoll();
      pausedTerminals.clear();
      // Connection drop tears every owned terminal down (no orphan PTYs).
      // Detach first: the socket is gone, so exit pushes would go nowhere.
      for (const entry of terminalEntries.values()) {
        entry.detach();
        void entry.opened.close().catch(() => {});
      }
      terminalEntries.clear();
      // Connection drop tears every owned script run down too (no orphan dev
      // servers). Detach first: the socket is gone, so exit pushes go nowhere.
      for (const entry of scriptEntries.values()) {
        entry.detach();
        void entry.opened.close().catch(() => {});
      }
      scriptEntries.clear();
      for (const unhook of sessionExitHooks.values()) unhook();
      sessionExitHooks.clear();
    },
  };
}

export interface RpcEndpoint {
  wss: WebSocketServer;
  /** Push a server message to every connected RPC client (wrapped as a frame). */
  broadcast: (message: ServerMessage) => void;
  /** Push a diff notification to every connected RPC client (Slice 9). */
  broadcastDiff: (message: DiffPush) => void;
}

export function setupRpcEndpoint(deps: {
  sessions: SessionManager;
  terminals: TerminalGateway;
  diffs: DiffGateway;
  editors: EditorLauncher;
  files: FileService;
  scripts: ScriptRunnerGateway;
  checkpoints: CheckpointServiceShape;
  rollback: CheckpointRollbackGateway;
}): RpcEndpoint {
  const { sessions, terminals, diffs, editors, files, scripts, checkpoints, rollback } = deps;

  const wss = new WebSocketServer({ noServer: true });
  const clients = new Set<WebSocket>();

  const sendTo = (socket: WebSocket, frame: RpcServerFrame): void => {
    if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(frame));
  };
  const broadcast = (message: ServerMessage): void => {
    for (const client of clients) sendTo(client, { kind: "push", message });
  };
  const broadcastDiff = (message: DiffPush): void => {
    for (const client of clients) sendTo(client, { kind: "diff_push", message });
  };

  wss.on("connection", (socket: WebSocket) => {
    clients.add(socket);
    const connection = createRpcConnection({
      sessions,
      terminals,
      diffs,
      editors,
      files,
      scripts,
      checkpoints,
      rollback,
      send: (frame) => sendTo(socket, frame),
      // Terminal push backpressure reads the real socket send-buffer depth.
      bufferedAmount: () => socket.bufferedAmount,
    });
    socket.on("close", () => {
      clients.delete(socket);
      connection.close();
    });
    socket.on("message", (raw: Buffer) => {
      void connection.handleMessage(raw.toString("utf8"));
    });
  });

  return { wss, broadcast, broadcastDiff };
}
