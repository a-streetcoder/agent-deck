import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * Issue detail route (native GitHubIssueDetailView 10.6): GET
 * /projects/:id/issues/:number runs `gh issue view <n> --json …` and maps its
 * output to {title, body, state, labels, assignees, author}. The gh CLI is
 * stubbed (unix shell script), so this leg runs on the ubuntu/macos runners.
 */

const isWindows = process.platform === "win32";

let server: AgentDeckServer;
let projectId: string;
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));
const projectDir = mkdtempSync(path.join(tmpdir(), "issues-detail-project-"));

beforeAll(async () => {
  // Stub gh: echo the requested issue number back so we can assert it was passed.
  const stub = path.join(mkdtempSync(path.join(tmpdir(), "gh-stub-")), "gh");
  writeFileSync(
    stub,
    `#!/bin/sh
num="$3"
cat <<JSON
{"number":$num,"title":"Flux capacitor","body":"# Steps\\nreproduce","state":"OPEN","url":"https://x/$num","labels":[{"name":"bug"},{"name":"p1"}],"assignees":[{"login":"marty"}],"author":{"login":"doc"}}
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

describe.skipIf(isWindows)("GET /projects/:id/issues/:number", () => {
  it("returns the mapped issue detail from gh issue view", async () => {
    const res = await fetch(`http://127.0.0.1:${server.port}/projects/${projectId}/issues/42`);
    expect(res.status).toBe(200);
    const { issue } = (await res.json()) as {
      issue: {
        number: number;
        title: string;
        body: string;
        state: string;
        labels: string[];
        assignees: string[];
        author: string | null;
      };
    };
    expect(issue.number).toBe(42); // the number was forwarded to `gh issue view 42`
    expect(issue.title).toBe("Flux capacitor");
    expect(issue.body).toContain("reproduce");
    expect(issue.labels).toEqual(["bug", "p1"]);
    expect(issue.assignees).toEqual(["marty"]);
    expect(issue.author).toBe("doc");
  });

  it("400s a non-numeric issue number without invoking gh", async () => {
    const res = await fetch(`http://127.0.0.1:${server.port}/projects/${projectId}/issues/abc`);
    expect(res.status).toBe(400);
  });

  it("404s an unknown project", async () => {
    const res = await fetch(`http://127.0.0.1:${server.port}/projects/nope/issues/1`);
    expect(res.status).toBe(404);
  });
});
