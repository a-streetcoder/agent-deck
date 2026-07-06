import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * Issues state filter (native Issues screen's Open / Closed / All): the server
 * forwards the requested state to `gh issue list --state <state>`. The gh CLI
 * is stubbed with a shell script that echoes back the --state it received, so
 * we can assert the server passes the filter through (and defaults to open).
 *
 * The stub is a unix shell script; on Windows gh runs natively, so this leg is
 * covered by the ubuntu/macos runners (mirrors the e2e issues stub's skip).
 */

const isWindows = process.platform === "win32";

let server: AgentDeckServer;
let projectId: string;
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));
const projectDir = mkdtempSync(path.join(tmpdir(), "issues-filter-project-"));

async function issuesFor(query: string): Promise<{ status: number; titles: string[] }> {
  const res = await fetch(`http://127.0.0.1:${server.port}/projects/${projectId}/issues${query}`);
  const body = (await res.json()) as { issues?: Array<{ title: string }> };
  return { status: res.status, titles: (body.issues ?? []).map((i) => i.title) };
}

beforeAll(async () => {
  // Stub gh: parse --state out of the args and echo it back in the issue title.
  const stub = path.join(mkdtempSync(path.join(tmpdir(), "gh-stub-")), "gh");
  writeFileSync(
    stub,
    `#!/bin/sh
state=none
while [ $# -gt 0 ]; do
  case "$1" in
    --state) shift; state="$1" ;;
  esac
  shift
done
cat <<JSON
[{"number":1,"title":"state=$state","state":"OPEN","url":"https://x/1","labels":[]}]
JSON
`,
  );
  chmodSync(stub, 0o755);
  process.env.AGENT_DECK_GH_BIN = stub;

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
  await server.close();
});

describe.skipIf(isWindows)("issues state filter", () => {
  it("defaults to open when no state is given", async () => {
    const { status, titles } = await issuesFor("");
    expect(status).toBe(200);
    expect(titles).toEqual(["state=open"]);
  });

  it("forwards each explicit state to gh", async () => {
    expect((await issuesFor("?state=open")).titles).toEqual(["state=open"]);
    expect((await issuesFor("?state=closed")).titles).toEqual(["state=closed"]);
    expect((await issuesFor("?state=all")).titles).toEqual(["state=all"]);
  });

  it("rejects an unknown state with 400", async () => {
    expect((await issuesFor("?state=bogus")).status).toBe(400);
  });
});
