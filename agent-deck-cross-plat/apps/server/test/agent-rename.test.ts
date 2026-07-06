import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * Agent rename route (native RenameResourceSheet 6.5): POST
 * /resources/agents/rename moves a global/project agent on disk (200 / 409 /
 * 404) AND re-points any project whose default named the old agent — the
 * reference update that a bare file move would leave dangling.
 */

const resourceHome = mkdtempSync(path.join(tmpdir(), "agent-rename-home-"));
const projectDir = mkdtempSync(path.join(tmpdir(), "agent-rename-proj-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));
let server: AgentDeckServer;
let projectId: string;

async function api(method: string, url: string, body?: unknown): Promise<Response> {
  return await fetch(`http://127.0.0.1:${server.port}${url}`, {
    method,
    headers: body === undefined ? {} : { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

async function defaultAgentOf(): Promise<string | undefined> {
  const { projects } = (await (await api("GET", "/projects")).json()) as {
    projects: Array<{ id: string; defaultAgentName?: string }>;
  };
  return projects.find((p) => p.id === projectId)!.defaultAgentName;
}

async function agentNames(): Promise<string[]> {
  const { agents } = (await (
    await api("GET", `/resources/agents?projectId=${projectId}`)
  ).json()) as { agents: Array<{ name: string; scope: string }> };
  return agents.filter((a) => a.scope === "project").map((a) => a.name);
}

beforeAll(async () => {
  process.env.AGENT_DECK_PI_ENV = JSON.stringify({ HOME: resourceHome });
  server = await startServer({ dataDir });
  projectId = (
    (await (await api("POST", "/projects", { path: projectDir })).json()) as {
      project: { id: string };
    }
  ).project.id;
  for (const name of ["helper", "other"]) {
    const res = await api("PUT", "/resources/agents", {
      projectId,
      scope: "project",
      name,
      edit: { description: name, body: `You are ${name}.` },
    });
    if (!res.ok) throw new Error(await res.text());
  }
  // Make "helper" the project default so the rename must re-point it.
  await api("PATCH", `/projects/${projectId}`, { defaultAgentName: "helper" });
});

afterAll(async () => {
  delete process.env.AGENT_DECK_PI_ENV;
  await server.close();
});

describe("POST /resources/agents/rename", () => {
  it("renames on disk AND re-points the project default", async () => {
    expect(await defaultAgentOf()).toBe("helper");

    const res = await api("POST", "/resources/agents/rename", {
      projectId,
      scope: "project",
      name: "helper",
      newName: "helper2",
    });
    expect(res.status).toBe(200);

    expect((await agentNames()).sort()).toEqual(["helper2", "other"]);
    // The dangling-reference fix: the default followed the rename.
    expect(await defaultAgentOf()).toBe("helper2");
  });

  it("409 on a name clash, leaving the default untouched", async () => {
    const res = await api("POST", "/resources/agents/rename", {
      projectId,
      scope: "project",
      name: "helper2",
      newName: "other",
    });
    expect(res.status).toBe(409);
    expect(await defaultAgentOf()).toBe("helper2");
  });

  it("404 when the source agent does not exist", async () => {
    const res = await api("POST", "/resources/agents/rename", {
      projectId,
      scope: "project",
      name: "ghost",
      newName: "x",
    });
    expect(res.status).toBe(404);
  });

  it("does NOT re-point a default that shadows the renamed global agent", async () => {
    // A project agent "shadowed" shadows a same-named global one; the default
    // resolves to the PROJECT agent.
    await api("PUT", "/resources/agents", {
      scope: "global",
      name: "shadowed",
      edit: { body: "g" },
    });
    await api("PUT", "/resources/agents", {
      projectId,
      scope: "project",
      name: "shadowed",
      edit: { body: "p" },
    });
    await api("PATCH", `/projects/${projectId}`, { defaultAgentName: "shadowed" });

    // Renaming the GLOBAL one must not touch the default (it pointed at the project agent).
    const res = await api("POST", "/resources/agents/rename", {
      scope: "global",
      name: "shadowed",
      newName: "shadowed2",
    });
    expect(res.status).toBe(200);
    expect(await defaultAgentOf()).toBe("shadowed");
  });

  it("DOES re-point a default that resolved to the renamed global agent", async () => {
    // "lonely" exists only globally, so the project default resolves to it.
    await api("PUT", "/resources/agents", { scope: "global", name: "lonely", edit: { body: "g" } });
    await api("PATCH", `/projects/${projectId}`, { defaultAgentName: "lonely" });

    const res = await api("POST", "/resources/agents/rename", {
      scope: "global",
      name: "lonely",
      newName: "lonely2",
    });
    expect(res.status).toBe(200);
    expect(await defaultAgentOf()).toBe("lonely2");
  });
});
