import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * Prompt rename route (native RenameResourceSheet): POST
 * /resources/prompts/rename moves a global/project prompt on disk, mapping the
 * writer's sentinels to 200 / 409 (name taken) / 404 (source gone). The
 * resource home follows AGENT_DECK_PI_ENV so the scan is hermetic.
 */

const resourceHome = mkdtempSync(path.join(tmpdir(), "prompt-home-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));
let server: AgentDeckServer;

async function api(method: string, url: string, body?: unknown): Promise<Response> {
  return await fetch(`http://127.0.0.1:${server.port}${url}`, {
    method,
    headers: body === undefined ? {} : { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

async function promptNames(): Promise<string[]> {
  const { prompts } = (await (await api("GET", "/resources/prompts")).json()) as {
    prompts: Array<{ name: string }>;
  };
  return prompts.map((p) => p.name).sort();
}

beforeAll(async () => {
  process.env.AGENT_DECK_PI_ENV = JSON.stringify({ HOME: resourceHome });
  server = await startServer({ dataDir });
  for (const name of ["review", "audit"]) {
    const res = await api("PUT", "/resources/prompts", {
      scope: "global",
      name,
      edit: { body: `body of ${name}` },
    });
    if (!res.ok) throw new Error(await res.text());
  }
});

afterAll(async () => {
  delete process.env.AGENT_DECK_PI_ENV;
  await server.close();
});

describe("POST /resources/prompts/rename", () => {
  it("409 when the target name already exists (both prompts untouched)", async () => {
    const res = await api("POST", "/resources/prompts/rename", {
      scope: "global",
      name: "review",
      newName: "audit",
    });
    expect(res.status).toBe(409);
    expect(await promptNames()).toEqual(["audit", "review"]);
  });

  it("404 when the source prompt does not exist", async () => {
    const res = await api("POST", "/resources/prompts/rename", {
      scope: "global",
      name: "ghost",
      newName: "whatever",
    });
    expect(res.status).toBe(404);
  });

  it("400 on an invalid new name", async () => {
    const res = await api("POST", "/resources/prompts/rename", {
      scope: "global",
      name: "review",
      newName: "bad name!",
    });
    expect(res.status).toBe(400);
  });

  it("renames on success and the catalog reflects the new name", async () => {
    const res = await api("POST", "/resources/prompts/rename", {
      scope: "global",
      name: "review",
      newName: "summary",
    });
    expect(res.status).toBe(200);
    expect(await promptNames()).toEqual(["audit", "summary"]);
  });
});
