import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  MOCK_MODEL_ID,
  MOCK_PROVIDER_ID,
  startMockProvider,
  writeMockProviderExtension,
  type MockProviderServer,
} from "@agent-deck/testkit";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * Commit-message generation (native PiAgentShipService) against real pi: POST
 * /projects/:id/git/generate-message runs a one-shot pi helper over the working-
 * tree diff and returns its message. The mock provider returns a fixed message,
 * proving the diff → helper → message round-trip.
 */

process.env.AGENT_DECK_TEST = "1";

const GENERATED = "Add a greeting helper\n\nAdds hello() so callers can greet users.";

let mock: MockProviderServer;
let server: AgentDeckServer;
let base: string;
let projectId: string;
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const project = mkdtempSync(path.join(tmpdir(), "pi-commitmsg-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));

function git(args: string[]): void {
  execFileSync("git", args, { cwd: project });
}

beforeAll(async () => {
  mock = await startMockProvider({ reply: () => GENERATED });
  process.env.AGENT_DECK_PROVIDER_EXTENSIONS = writeMockProviderExtension(mock.baseUrl);
  process.env.AGENT_DECK_DEFAULT_PROVIDER = MOCK_PROVIDER_ID;
  process.env.AGENT_DECK_DEFAULT_MODEL = MOCK_MODEL_ID;
  process.env.AGENT_DECK_PI_ENV = JSON.stringify({
    HOME: tmpHome,
    USERPROFILE: tmpHome,
    PI_SKIP_VERSION_CHECK: "1",
  });

  execFileSync("git", ["init", "-b", "main", project]);
  git(["config", "user.email", "t@t.local"]);
  git(["config", "user.name", "T"]);
  writeFileSync(path.join(project, "greet.js"), "export function hello() {}\n");
  git(["add", "-A"]);
  git(["commit", "-m", "init"]);
  // An uncommitted change for the message generator to describe.
  writeFileSync(path.join(project, "greet.js"), "export function hello() {\n  return 'hi';\n}\n");

  server = await startServer({ dataDir });
  base = `http://127.0.0.1:${server.port}`;
  projectId = (
    (await (
      await fetch(`${base}/projects`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ path: project }),
      })
    ).json()) as { project: { id: string } }
  ).project.id;
});

afterAll(async () => {
  await server.close();
  await mock.close();
  delete process.env.AGENT_DECK_PROVIDER_EXTENSIONS;
  delete process.env.AGENT_DECK_DEFAULT_PROVIDER;
  delete process.env.AGENT_DECK_DEFAULT_MODEL;
  delete process.env.AGENT_DECK_PI_ENV;
});

describe("git commit-message generation (real pi)", () => {
  it("generates a message from the working-tree diff via a pi helper", async () => {
    const res = await fetch(`${base}/projects/${projectId}/git/generate-message`, {
      method: "POST",
    });
    expect(res.status).toBe(200);
    const { message } = (await res.json()) as { message: string };
    expect(message).toContain("Add a greeting helper");
  });

  it("400s when the working tree is clean", async () => {
    git(["checkout", "--", "greet.js"]); // discard the uncommitted change
    const res = await fetch(`${base}/projects/${projectId}/git/generate-message`, {
      method: "POST",
    });
    expect(res.status).toBe(400);
    expect(await res.text()).toContain("no changes");
  });
});
