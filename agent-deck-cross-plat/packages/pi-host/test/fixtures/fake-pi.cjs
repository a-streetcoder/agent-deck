// A scripted stand-in for `pi --mode rpc`: reads JSONL commands on stdin and
// replies per command type, so PiSession correlation can be tested hermetically.
const readline = require("node:readline");

const rl = readline.createInterface({ input: process.stdin, terminal: false });

function send(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

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
    case "set_session_name":
      if (cmd.name === "fail") {
        send({
          id: cmd.id,
          type: "response",
          command: "set_session_name",
          success: false,
          error: "boom",
        });
      } else {
        send({ id: cmd.id, type: "response", command: "set_session_name", success: true });
      }
      break;
    case "compact":
      // Never respond — exercises the timeout path.
      break;
    case "prompt":
      // Ack, then stream events, including a malformed line.
      send({ id: cmd.id, type: "response", command: "prompt", success: true });
      send({ type: "turn_start" });
      send({ type: "message_update", assistantMessageEvent: { type: "text_delta", delta: "he" } });
      process.stdout.write("this is not json\n");
      send({ type: "message_update", assistantMessageEvent: { type: "text_delta", delta: "llo" } });
      send({ type: "agent_end" });
      break;
    case "abort":
      // Exit without responding — exercises reject-pending-on-exit.
      process.exit(0);
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
