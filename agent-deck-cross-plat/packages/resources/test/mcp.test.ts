import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { beforeEach, describe, expect, it } from "vitest";
import {
  deleteMcpServer,
  isValidMcpServerName,
  mcpConfigPath,
  McpConfigError,
  readMcpServers,
  writeMcpServer,
  type ResourceRoots,
} from "../src/index.ts";

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

describe("writeMcpServer / deleteMcpServer", () => {
  it("adds a server and reads it back (creating the file)", () => {
    writeMcpServer(roots, "global", "files", { command: "npx", args: ["-y", "server-fs"] });
    const byId = Object.fromEntries(readMcpServers(roots).map((s) => [s.id, s]));
    expect(byId.files).toMatchObject({ transport: "stdio", command: "npx", scope: "global" });
  });

  it("preserves unknown top-level keys and other servers on write", () => {
    const file = mcpConfigPath(roots, "global")!;
    mkdirSync(path.dirname(file), { recursive: true });
    writeFileSync(
      file,
      JSON.stringify({ someOtherKey: 42, mcpServers: { keep: { command: "keep" } } }),
    );
    writeMcpServer(roots, "global", "added", { url: "https://x/mcp" });
    const doc = JSON.parse(readFileSync(file, "utf8")) as Record<string, unknown>;
    expect(doc.someOtherKey).toBe(42);
    expect(Object.keys(doc.mcpServers as object).sort()).toEqual(["added", "keep"]);
  });

  it("replaces an existing server of the same name", () => {
    writeMcpServer(roots, "global", "db", { command: "old" });
    writeMcpServer(roots, "global", "db", { command: "new" });
    const db = readMcpServers(roots).find((s) => s.id === "db");
    expect(db?.command).toBe("new");
  });

  it("deletes a server (and reports whether it existed)", () => {
    writeMcpServer(roots, "global", "gone", { command: "x" });
    expect(deleteMcpServer(roots, "global", "gone")).toBe(true);
    expect(readMcpServers(roots)).toEqual([]);
    expect(deleteMcpServer(roots, "global", "gone")).toBe(false);
  });

  it("rejects unsafe names and empty command/url", () => {
    expect(isValidMcpServerName("__proto__")).toBe(false);
    expect(isValidMcpServerName("a/b")).toBe(false);
    expect(isValidMcpServerName("ok-name.1")).toBe(true);
    expect(() => writeMcpServer(roots, "global", "__proto__", { command: "x" })).toThrow(
      McpConfigError,
    );
    expect(() => writeMcpServer(roots, "global", "ok", { command: "  " })).toThrow(McpConfigError);
    // Prototype pollution guard: a rejected name never lands on the object proto.
    expect(({} as Record<string, unknown>).polluted).toBeUndefined();
  });

  it("throws for project scope without an open project", () => {
    const noProject: ResourceRoots = { home: roots.home };
    expect(() => writeMcpServer(noProject, "project", "x", { command: "y" })).toThrow(
      McpConfigError,
    );
  });

  it("refuses to overwrite an existing malformed mcp.json (no data loss)", () => {
    const file = mcpConfigPath(roots, "global")!;
    mkdirSync(path.dirname(file), { recursive: true });
    writeFileSync(file, "{ this is broken json");
    expect(() => writeMcpServer(roots, "global", "x", { command: "y" })).toThrow(McpConfigError);
    // The broken file is left untouched.
    expect(readFileSync(file, "utf8")).toBe("{ this is broken json");
  });
});
