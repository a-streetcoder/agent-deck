/* global setTimeout, setInterval, clearInterval */
// A scripted stand-in for `pi --mode rpc`, driven over stdin/stdout JSONL, so
// the PiHost Effect service (src/services/piHost.ts) can be tested hermetically:
// out-of-order correlation, exit-with-pending, abort mid-turn, malformed lines.
const readline = require("node:readline");

const rl = readline.createInterface({ input: process.stdin, terminal: false });

function send(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

let streamTimer = null;
let streamed = 0;

rl.on("line", (line) => {
  let cmd;
  try {
    cmd = JSON.parse(line);
  } catch {
    return;
  }
  switch (cmd.type) {
    case "get_state":
      send({
        id: cmd.id,
        type: "response",
        command: "get_state",
        success: true,
        data: { sessionId: "fake-session", isStreaming: false, thinkingLevel: "off" },
      });
      break;
    case "get_session_stats":
      // Delayed reply — lands AFTER any get_state issued later (out-of-order).
      setTimeout(() => {
        send({
          id: cmd.id,
          type: "response",
          command: "get_session_stats",
          success: true,
          data: { tokens: 123 },
        });
      }, 150);
      break;
    case "set_session_name":
      if (cmd.name === "fail") {
        send({
          id: cmd.id,
          type: "response",
          command: "set_session_name",
          success: false,
          error: "boom",
        });
      } else if (cmd.name === "exit") {
        // Exit WITHOUT responding — pending RPCs must fail, never hang.
        process.exit(3);
      } else if (cmd.name === "burst-exit") {
        // A final burst of events followed by immediate death: the write
        // callback only guarantees the OS pipe RECEIVED the bytes, so the
        // reader can still observe the process exit while lines sit
        // undelivered in the pipe — the drain-gated exit must deliver them
        // all before the terminating ProcessExit.
        let payload = "";
        for (let i = 0; i < 200; i++) {
          payload += `${JSON.stringify({ type: "burst", n: i })}\n`;
        }
        process.stdout.write(payload, () => process.exit(7));
      } else if (cmd.name === "ignore-sigterm") {
        // Refuse the graceful shutdown signal so PiProcess.stop() must
        // escalate to SIGKILL after its grace period. POSIX-only semantics:
        // on Windows there is no graceful path to refuse (taskkill /F is an
        // unconditional TerminateProcess), so the handler is a harmless no-op.
        process.on("SIGTERM", () => {});
        send({ id: cmd.id, type: "response", command: "set_session_name", success: true });
      } else if (cmd.name === "spawn-stubborn-child") {
        // Kill-escalation + tree-kill combined: this process AND a spawned
        // grandchild both ignore SIGTERM, so only the escalated kill (POSIX:
        // SIGKILL to the process group; Windows: taskkill /T /F) reaps them.
        process.on("SIGTERM", () => {});
        const { spawn } = require("node:child_process");
        const stubborn = spawn(
          process.execPath,
          ["-e", "process.on('SIGTERM', () => {}); setInterval(() => {}, 1000);"],
          { stdio: "ignore" },
        );
        send({ type: "child_pid", pid: stubborn.pid });
        send({ id: cmd.id, type: "response", command: "set_session_name", success: true });
      } else if (cmd.name === "spawn-child") {
        // Spawn a long-lived grandchild (a stand-in for pi's stdio MCP
        // servers / subagents) and report its pid as an event — the tree
        // kill on scope close must reap it too.
        const { spawn } = require("node:child_process");
        const grandchild = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], {
          stdio: "ignore",
        });
        send({ type: "child_pid", pid: grandchild.pid });
        send({ id: cmd.id, type: "response", command: "set_session_name", success: true });
      } else {
        send({ id: cmd.id, type: "response", command: "set_session_name", success: true });
      }
      break;
    case "compact":
      // Never respond — exercises the timeout path.
      break;
    case "prompt":
      send({ id: cmd.id, type: "response", command: "prompt", success: true });
      send({ type: "turn_start" });
      if (cmd.message === "stream-forever") {
        // A turn that never ends by itself — only `abort` stops it.
        streamTimer = setInterval(() => {
          streamed += 1;
          send({
            type: "message_update",
            assistantMessageEvent: { type: "text_delta", delta: `chunk-${streamed} ` },
          });
        }, 15);
      } else {
        send({
          type: "message_update",
          assistantMessageEvent: { type: "text_delta", delta: "he" },
        });
        process.stdout.write("this is not json\n");
        send({
          type: "message_update",
          assistantMessageEvent: { type: "text_delta", delta: "llo" },
        });
        send({ type: "agent_end" });
      }
      break;
    case "abort":
      if (streamTimer) {
        clearInterval(streamTimer);
        streamTimer = null;
      }
      send({ id: cmd.id, type: "response", command: "abort", success: true });
      send({ type: "agent_end" });
      break;
    default:
      send({
        id: cmd.id,
        type: "response",
        command: cmd.type,
        success: false,
        error: `unknown: ${cmd.type}`,
      });
  }
});
