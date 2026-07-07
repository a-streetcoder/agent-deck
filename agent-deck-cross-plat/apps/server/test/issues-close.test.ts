import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * Close-issue route (native Issues close split-button 10.9): POST
 * /projects/:id/issues/:number/close forwards `gh issue close <n> --reason
 * <completed|"not planned">`. The gh stub logs its argv so we can assert the
 * exact command (unix shell script → ubuntu/macos runners).
 */

const isWindows = process.platform === "win32";

let server: AgentDeckServer;
let projectId: string;
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));
const projectDir = mkdtempSync(path.join(tmpdir(), "issues-close-project-"));
const argsLog = path.join(mkdtempSync(path.join(tmpdir(), "gh-log-")), "args.log");

async function close(number: string, body?: unknown): Promise<number> {
  const res = await fetch(
    `http://127.0.0.1:${server.port}/projects/${projectId}/issues/${number}/close`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body ?? {}),
    },
  );
  return res.status;
}

beforeAll(async () => {
  const stub = path.join(mkdtempSync(path.join(tmpdir(), "gh-stub-")), "gh");
  writeFileSync(stub, `#!/bin/sh\necho "$@" >> "$GH_ARGS_LOG"\nexit 0\n`);
  chmodSync(stub, 0o755);
  process.env.AGENT_DECK_GH_BIN = stub;
  process.env.GH_ARGS_LOG = argsLog;

  server = await startServer({ dataDir });
  const created = (await (
    await fetch(`http://127.0.0.1:${server.port}/projects`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path: projectDir }),
    })
  ).json()) as { project: { id: string } };
  projectId = created.project.id;
});

afterAll(async () => {
  delete process.env.AGENT_DECK_GH_BIN;
  delete process.env.GH_ARGS_LOG;
  await server.close();
});

describe.skipIf(isWindows)("POST /projects/:id/issues/:number/close", () => {
  it("forwards `issue close <n> --reason completed`", async () => {
    expect(await close("7", { reason: "completed" })).toBe(200);
    expect(readFileSync(argsLog, "utf8")).toContain("issue close 7 --reason completed");
  });

  it("maps not_planned to gh's `not planned` reason", async () => {
    expect(await close("9", { reason: "not_planned" })).toBe(200);
    expect(readFileSync(argsLog, "utf8")).toContain("issue close 9 --reason not planned");
  });

  it("400s an unknown reason without invoking gh", async () => {
    expect(await close("7", { reason: "bogus" })).toBe(400);
  });

  it("400s a non-numeric issue number", async () => {
    expect(await close("abc", { reason: "completed" })).toBe(400);
  });
});
