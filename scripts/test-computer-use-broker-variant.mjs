#!/usr/bin/env node
import assert from "node:assert/strict";
import { lstat, mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const root = process.env.AGENT_DECK_COMPUTER_USE_BROKER_ROOT
  ?? path.join(os.homedir(), "Library/Application Support/Agent Deck/Computer Use Broker");
const packageRoot = path.join(root, "Variants/0.2.0-agent-deck-auto-accept.2/node_modules/codex-computer-use-mcp");
const { callOfficialDirectTool } = await import(pathToFileURL(path.join(packageRoot, "dist/direct-broker.js")));
const { appendAudit } = await import(pathToFileURL(path.join(packageRoot, "dist/audit.js")));
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
  const maxAuditBytes = 5 * 1024 * 1024;
  const auditState = path.join(temp, "bounded-audit-state");
  for (let index = 0; index < 6; index += 1) {
    await appendAudit(auditState, { index, padding: "x".repeat(1024 * 1024) });
  }
  const auditPath = path.join(auditState, "audit/direct-computer-use.jsonl");
  const backupPath = `${auditPath}.1`;
  const [auditInfo, backupInfo] = await Promise.all([stat(auditPath), stat(backupPath)]);
  assert.ok(auditInfo.size <= maxAuditBytes);
  assert.ok(backupInfo.size <= maxAuditBytes);
  assert.ok(auditInfo.size + backupInfo.size <= 2 * maxAuditBytes);
  assert.equal(auditInfo.mode & 0o777, 0o600);
  assert.equal(backupInfo.mode & 0o777, 0o600);
  for (const file of [auditPath, backupPath]) {
    for (const line of (await readFile(file, "utf8")).trim().split("\n")) JSON.parse(line);
  }

  const legacyState = path.join(temp, "oversized-legacy-audit-state");
  const legacyAuditDirectory = path.join(legacyState, "audit");
  await mkdir(legacyAuditDirectory, { recursive: true, mode: 0o700 });
  const legacyAuditPath = path.join(legacyAuditDirectory, "direct-computer-use.jsonl");
  await writeFile(legacyAuditPath, "x".repeat(maxAuditBytes + 1), { mode: 0o600 });
  await writeFile(`${legacyAuditPath}.1`, "x".repeat(maxAuditBytes + 1), { mode: 0o600 });
  await appendAudit(legacyState, { reset: true });
  assert.ok((await stat(legacyAuditPath)).size < 1024);
  await assert.rejects(lstat(`${legacyAuditPath}.1`), error => error?.code === "ENOENT");

  await assert.rejects(
    appendAudit(path.join(temp, "oversized-record-state"), { padding: "x".repeat(maxAuditBytes) }),
    /exceeds the maximum audit file size/,
  );

  console.log("Computer Use auto-accept and bounded-audit variant tests passed");
} finally {
  await rm(temp, { recursive: true, force: true });
}
