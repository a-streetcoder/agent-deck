import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { beforeEach, describe, expect, it } from "vitest";
import { mcpConfigPath, readMcpServers, type ResourceRoots } from "../src/index.ts";

let roots: ResourceRoots;

beforeEach(() => {
  roots = {
    home: mkdtempSync(path.join(tmpdir(), "mcp-home-")),
    projectPath: mkdtempSync(path.join(tmpdir(), "mcp-proj-")),
  };
});

function writeGlobal(config: unknown): void {
  const file = mcpConfigPath(roots, "global")!;
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, JSON.stringify(config));
}

function writeProject(config: unknown): void {
  const file = mcpConfigPath(roots, "project")!;
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, JSON.stringify(config));
}

describe("readMcpServers", () => {
  it("returns [] when no mcp.json exists", () => {
    expect(readMcpServers(roots)).toEqual([]);
  });

  it("parses stdio and http entries from the standard mcp.json format", () => {
    writeGlobal({
      mcpServers: {
        files: { command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"] },
        remote: { url: "https://example.com/mcp" },
        broken: { neither: true },
      },
    });
    const servers = readMcpServers(roots);
    const byId = Object.fromEntries(servers.map((s) => [s.id, s]));
    expect(byId.files).toMatchObject({
      transport: "stdio",
      command: "npx",
      args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
      scope: "global",
    });
    expect(byId.remote).toMatchObject({ transport: "http", url: "https://example.com/mcp" });
    // An entry with neither command nor url is skipped.
    expect(byId.broken).toBeUndefined();
  });

  it("lets a project entry override a global one of the same name", () => {
    writeGlobal({ mcpServers: { db: { command: "global-db" } } });
    writeProject({ mcpServers: { db: { command: "project-db" }, extra: { command: "x" } } });
    const byId = Object.fromEntries(readMcpServers(roots).map((s) => [s.id, s]));
    expect(byId.db).toMatchObject({ command: "project-db", scope: "project" });
    expect(byId.extra).toMatchObject({ command: "x", scope: "project" });
  });

  it("ignores malformed json and non-object mcpServers", () => {
    const file = mcpConfigPath(roots, "global")!;
    mkdirSync(path.dirname(file), { recursive: true });
    writeFileSync(file, "{ not valid json");
    expect(readMcpServers(roots)).toEqual([]);
    writeGlobal({ mcpServers: "nope" });
    expect(readMcpServers(roots)).toEqual([]);
  });
});
