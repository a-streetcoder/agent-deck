import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * Skill rename route (native RenameResourceSheet): POST
 * /resources/skills/rename moves a skill directory (200 / 409 / 404) AND
 * re-points every reference — app-level default/disabled lists and per-project
 * assignments — so an assignment never silently drops (and a shadowing project
 * skill is left alone when the global one is renamed).
 */

const resourceHome = mkdtempSync(path.join(tmpdir(), "skill-rename-home-"));
const projectDir = mkdtempSync(path.join(tmpdir(), "skill-rename-proj-"));
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

async function assignedOf(): Promise<string[]> {
  const { projects } = (await (await api("GET", "/projects")).json()) as {
    projects: Array<{ id: string; assignedSkills?: string[] }>;
  };
  return projects.find((p) => p.id === projectId)!.assignedSkills ?? [];
}

async function defaultSkills(): Promise<string[]> {
  const { settings } = (await (await api("GET", "/settings")).json()) as {
    settings: { defaultSkills: string[] };
  };
  return settings.defaultSkills;
}

async function writeSkill(scope: "global" | "project", name: string): Promise<void> {
  const res = await api("PUT", "/resources/skills", {
    projectId: scope === "project" ? projectId : undefined,
    scope,
    name,
    edit: { description: name, body: `Skill ${name}` },
  });
  if (!res.ok) throw new Error(await res.text());
}

beforeAll(async () => {
  process.env.AGENT_DECK_PI_ENV = JSON.stringify({ HOME: resourceHome });
  server = await startServer({ dataDir });
  projectId = (
    (await (await api("POST", "/projects", { path: projectDir })).json()) as {
      project: { id: string };
    }
  ).project.id;
});

afterAll(async () => {
  delete process.env.AGENT_DECK_PI_ENV;
  await server.close();
});

describe("POST /resources/skills/rename", () => {
  it("renames the dir AND re-points the project assignment + default list", async () => {
    await writeSkill("global", "linter");
    await api("PATCH", "/settings", { setDefaultSkill: { name: "linter", enabled: true } });
    await api("PATCH", `/projects/${projectId}`, { assignedSkills: ["linter"] });

    const res = await api("POST", "/resources/skills/rename", {
      scope: "global",
      name: "linter",
      newName: "formatter",
    });
    expect(res.status).toBe(200);

    expect(await assignedOf()).toEqual(["formatter"]);
    expect(await defaultSkills()).toContain("formatter");
    expect(await defaultSkills()).not.toContain("linter");
  });

  it("does NOT re-point an assignment that shadows the renamed global skill", async () => {
    // A project skill "shared" shadows a same-named global one; the assignment
    // resolves to the PROJECT skill.
    await writeSkill("global", "shared");
    await writeSkill("project", "shared");
    await api("PATCH", `/projects/${projectId}`, { assignedSkills: ["formatter", "shared"] });

    const res = await api("POST", "/resources/skills/rename", {
      scope: "global",
      name: "shared",
      newName: "shared2",
    });
    expect(res.status).toBe(200);
    // "shared" stays (it named the project skill); "formatter" untouched.
    expect((await assignedOf()).sort()).toEqual(["formatter", "shared"]);
  });

  it("leaves the flat default list alone when the old name still resolves (shadow)", async () => {
    // "dup" exists both globally and as a project skill; it's an app-level default.
    await writeSkill("global", "dup");
    await writeSkill("project", "dup");
    await api("PATCH", "/settings", { setDefaultSkill: { name: "dup", enabled: true } });

    const res = await api("POST", "/resources/skills/rename", {
      scope: "global",
      name: "dup",
      newName: "dup2",
    });
    expect(res.status).toBe(200);
    // The project "dup" still resolves the name, so the flat default must NOT be
    // redirected to the renamed global (that would misdirect the shadowing project).
    expect(await defaultSkills()).toContain("dup");
    expect(await defaultSkills()).not.toContain("dup2");
  });

  it("re-points a default whose name is fully gone after a project-scope rename", async () => {
    // "solo" exists only as this project's skill, yet sits in the app defaults.
    await writeSkill("project", "solo");
    await api("PATCH", "/settings", { setDefaultSkill: { name: "solo", enabled: true } });

    const res = await api("POST", "/resources/skills/rename", {
      projectId,
      scope: "project",
      name: "solo",
      newName: "solo2",
    });
    expect(res.status).toBe(200);
    // No skill named "solo" remains anywhere → the default follows the rename.
    expect(await defaultSkills()).toContain("solo2");
    expect(await defaultSkills()).not.toContain("solo");
  });

  it("409 on a name clash and 404 on a missing source", async () => {
    await writeSkill("global", "clashme");
    expect(
      (
        await api("POST", "/resources/skills/rename", {
          scope: "global",
          name: "formatter",
          newName: "clashme",
        })
      ).status,
    ).toBe(409);
    expect(
      (
        await api("POST", "/resources/skills/rename", {
          scope: "global",
          name: "ghost",
          newName: "z",
        })
      ).status,
    ).toBe(404);
  });
});
