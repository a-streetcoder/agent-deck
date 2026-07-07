import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * Instructions CLAUDE.md fallback: pi loads the first of AGENTS.md / AGENTS.MD /
 * CLAUDE.md / CLAUDE.MD it finds (AGENTS wins), so the editor resolves that
 * effective file — a CLAUDE.md project isn't shown an empty AGENTS.md editor.
 */

let server: AgentDeckServer;
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));

async function api(method: string, url: string, body?: unknown): Promise<Response> {
  return await fetch(`http://127.0.0.1:${server.port}${url}`, {
    method,
    headers: body === undefined ? {} : { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

async function registerProject(dir: string): Promise<string> {
  const created = (await (await api("POST", "/projects", { path: dir })).json()) as {
    project: { id: string };
  };
  return created.project.id;
}

beforeAll(async () => {
  server = await startServer({ dataDir });
});

afterAll(async () => {
  await server.close();
});

describe("instructions CLAUDE.md fallback", () => {
  it("edits CLAUDE.md when a project has it and no AGENTS.md", async () => {
    const projectDir = mkdtempSync(path.join(tmpdir(), "proj-claude-"));
    writeFileSync(path.join(projectDir, "CLAUDE.md"), "# Claude rules\n\nBe terse.");
    const id = await registerProject(projectDir);

    const { content, path: filePath } = (await (
      await api("GET", `/projects/${id}/instructions`)
    ).json()) as { content: string; path: string };
    expect(content).toContain("Be terse.");
    expect(path.basename(filePath)).toBe("CLAUDE.md");

    // A save writes back to CLAUDE.md — it does NOT create a shadowing AGENTS.md.
    expect((await api("PUT", `/projects/${id}/instructions`, { content: "updated" })).status).toBe(
      200,
    );
    expect(readFileSync(path.join(projectDir, "CLAUDE.md"), "utf8")).toBe("updated");
    expect(existsSync(path.join(projectDir, "AGENTS.md"))).toBe(false);
  });

  it("prefers AGENTS.md when both exist (pi precedence)", async () => {
    const projectDir = mkdtempSync(path.join(tmpdir(), "proj-both-"));
    writeFileSync(path.join(projectDir, "AGENTS.md"), "agents wins");
    writeFileSync(path.join(projectDir, "CLAUDE.md"), "claude loses");
    const id = await registerProject(projectDir);

    const { content, path: filePath } = (await (
      await api("GET", `/projects/${id}/instructions`)
    ).json()) as { content: string; path: string };
    expect(content).toBe("agents wins");
    expect(path.basename(filePath)).toBe("AGENTS.md");
  });

  it("defaults a fresh project to AGENTS.md", async () => {
    const projectDir = mkdtempSync(path.join(tmpdir(), "proj-fresh-"));
    const id = await registerProject(projectDir);
    const { path: filePath } = (await (
      await api("GET", `/projects/${id}/instructions`)
    ).json()) as { path: string };
    expect(path.basename(filePath)).toBe("AGENTS.md");
  });
});
