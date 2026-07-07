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

describe("prompt rename/delete re-points assignments (native defaultPromptTemplateNames + assignedPromptTemplateNames)", () => {
  let projectId: string;

  it("rename re-points the default list AND a project's assignedPrompts", async () => {
    await api("PUT", "/resources/prompts", {
      scope: "global",
      name: "deploy",
      edit: { body: "b" },
    });
    const projectDir = mkdtempSync(path.join(tmpdir(), "prompt-assign-project-"));
    const { project } = (await (await api("POST", "/projects", { path: projectDir })).json()) as {
      project: { id: string };
    };
    projectId = project.id;

    await api("PATCH", "/settings", {
      setDefaultPromptTemplate: { name: "deploy", enabled: true },
    });
    expect(
      (await api("PATCH", `/projects/${projectId}`, { assignedPrompts: ["deploy"] })).status,
    ).toBe(200);

    expect(
      (
        await api("POST", "/resources/prompts/rename", {
          scope: "global",
          name: "deploy",
          newName: "release",
        })
      ).status,
    ).toBe(200);

    const { settings } = (await (await api("GET", "/settings")).json()) as {
      settings: { defaultPromptTemplates: string[] };
    };
    expect(settings.defaultPromptTemplates).toContain("release");
    expect(settings.defaultPromptTemplates).not.toContain("deploy");

    const { projects } = (await (await api("GET", "/projects")).json()) as {
      projects: Array<{ id: string; assignedPrompts?: string[] }>;
    };
    expect(projects.find((p) => p.id === projectId)!.assignedPrompts).toEqual(["release"]);
  });

  it("global rename re-points an assignment even when the project has its OWN same-named prompt (global-first)", async () => {
    // A global "shared" AND a project-local "shared"; the project's assignment
    // resolves to the GLOBAL (prompts are global-first), so renaming the global
    // must re-point it — NOT skip it like the skill (shadowing) rule would.
    await api("PUT", "/resources/prompts", {
      scope: "global",
      name: "shared",
      edit: { body: "g" },
    });
    await api("PUT", "/resources/prompts", {
      scope: "project",
      projectId,
      name: "shared",
      edit: { body: "p" },
    });
    expect(
      (await api("PATCH", `/projects/${projectId}`, { assignedPrompts: ["shared"] })).status,
    ).toBe(200);

    expect(
      (
        await api("POST", "/resources/prompts/rename", {
          scope: "global",
          name: "shared",
          newName: "common",
        })
      ).status,
    ).toBe(200);

    const { projects } = (await (await api("GET", "/projects")).json()) as {
      projects: Array<{ id: string; assignedPrompts?: string[] }>;
    };
    expect(projects.find((p) => p.id === projectId)!.assignedPrompts).toEqual(["common"]);
  });

  it("project rename does NOT re-point an assignment that a global shadows-first", async () => {
    // "common" now exists globally (from the prior test) and as a project prompt.
    // The project's assignment "common" resolves to the GLOBAL, so renaming the
    // PROJECT's own "common" must leave the assignment pointing at the global.
    await api("PUT", "/resources/prompts", {
      scope: "project",
      projectId,
      name: "common",
      edit: { body: "p2" },
    });
    expect(
      (await api("PATCH", `/projects/${projectId}`, { assignedPrompts: ["common"] })).status,
    ).toBe(200);

    expect(
      (
        await api("POST", "/resources/prompts/rename", {
          scope: "project",
          projectId,
          name: "common",
          newName: "local-only",
        })
      ).status,
    ).toBe(200);

    const { projects } = (await (await api("GET", "/projects")).json()) as {
      projects: Array<{ id: string; assignedPrompts?: string[] }>;
    };
    // Unchanged: the assignment still names the global "common".
    expect(projects.find((p) => p.id === projectId)!.assignedPrompts).toEqual(["common"]);
  });

  it("delete drops the default and the project assignment", async () => {
    expect(
      (await api("DELETE", "/resources/prompts", { scope: "global", name: "release" })).status,
    ).toBe(200);

    const { settings } = (await (await api("GET", "/settings")).json()) as {
      settings: { defaultPromptTemplates: string[] };
    };
    expect(settings.defaultPromptTemplates).not.toContain("release");

    const { projects } = (await (await api("GET", "/projects")).json()) as {
      projects: Array<{ id: string; assignedPrompts?: string[] }>;
    };
    expect(projects.find((p) => p.id === projectId)!.assignedPrompts ?? []).not.toContain(
      "release",
    );
  });
});
