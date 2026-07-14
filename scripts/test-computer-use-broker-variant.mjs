#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const root = process.env.AGENT_DECK_COMPUTER_USE_BROKER_ROOT
  ?? path.join(os.homedir(), "Library/Application Support/Agent Deck/Computer Use Broker");
const packageRoot = path.join(root, "Variants/0.2.0-agent-deck-auto-accept.1/node_modules/codex-computer-use-mcp");
const { callOfficialDirectTool } = await import(pathToFileURL(path.join(packageRoot, "dist/direct-broker.js")));
const temp = await mkdtemp(path.join(os.tmpdir(), "agent-deck-auto-accept-test."));
const fakeServer = path.join(temp, "fake-app-server.mjs");
const toolsURL = pathToFileURL(path.join(packageRoot, "dist/tools.js")).href;

await writeFile(fakeServer, `
import readline from "node:readline";
import { EXPECTED_OFFICIAL_INPUT_SCHEMAS, OFFICIAL_METHODS } from ${JSON.stringify(toolsURL)};
const mode = process.argv[2];
const threadId = "test-ephemeral-thread";
let pendingTool;
const send = value => process.stdout.write(JSON.stringify(value) + "\\n");
const tools = Object.fromEntries(OFFICIAL_METHODS.map(name => [name, { inputSchema: EXPECTED_OFFICIAL_INPUT_SCHEMAS[name] }]));
readline.createInterface({ input: process.stdin }).on("line", line => {
  const message = JSON.parse(line);
  if (message.method === "initialize") return send({ id: message.id, result: {} });
  if (message.method === "initialized") return;
  if (message.method === "thread/start") return send({ id: message.id, result: { thread: { id: threadId, ephemeral: true, path: null, turns: [] } } });
  if (message.method === "mcpServerStatus/list") return send({ id: message.id, result: { data: [{ name: "computer-use", tools }] } });
  if (message.method === "mcpServer/tool/call") {
    pendingTool = message.id;
    const params = {
      threadId,
      turnId: null,
      serverName: "computer-use",
      mode: "form",
      _meta: { persist: ["always"] },
      message: "Allow ChatGPT to use TextEdit?",
      requestedSchema: { type: "object", properties: {} },
    };
    if (mode === "malformed-top") params.unexpected = true;
    if (mode === "malformed-meta") params._meta.unexpected = true;
    if (mode === "malformed-message") params.message = "Allow ChatGPT to use TextEdit\\n?";
    return send({ id: "approval-1", method: "mcpServer/elicitation/request", params });
  }
  if (message.id === "approval-1") {
    if (message.result?.action === "accept") {
      return send({ id: pendingTool, result: { content: [{ type: "text", text: "accepted" }], isError: false } });
    }
    return send({ id: pendingTool, result: { content: [{ type: "text", text: "declined" }], isError: true } });
  }
});
`);

try {
  const valid = await callOfficialDirectTool("get_app_state", { app: "com.apple.TextEdit" }, {
    appServerCommand: process.execPath,
    appServerArgs: [fakeServer, "valid"],
    skipSignatureVerification: true,
  });
  assert.equal(valid.isError, false);
  assert.equal(valid.approvalRequests, 1);
  assert.equal(valid.content[0].text, "accepted");

  for (const mode of ["malformed-top", "malformed-meta", "malformed-message"]) {
    await assert.rejects(
      callOfficialDirectTool("get_app_state", { app: "com.apple.TextEdit" }, {
        appServerCommand: process.execPath,
        appServerArgs: [fakeServer, mode],
        skipSignatureVerification: true,
      }),
      /unexpected Computer Use approval request/,
    );
  }
  console.log("Computer Use auto-accept variant protocol tests passed");
} finally {
  await rm(temp, { recursive: true, force: true });
}
