import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { agentCatalogDirs } from "../src/paths.ts";
import { scanAgents } from "../src/scanner.ts";
import { renameAgentFile, writeAgentFile } from "../src/writer.ts";

/**
 * Agent rename (native RenameResourceSheet 6.5): move a global/project agent's
 * .md file, preserving body + frontmatter and syncing `name`. Builtins are not
 * renameable (their name is the settings.json override key), so this only
 * covers writable scopes. Shares renameMarkdownFile with prompt rename, so the
 * cross-platform/TOCTOU behaviour is exercised there too.
 */

function home(): string {
  return mkdtempSync(path.join(tmpdir(), "agent-rename-home-"));
}

function globalAgentPath(roots: { home: string }, name: string): string {
  const dir = agentCatalogDirs(roots).find((d) => d.scope === "global" && !d.legacy)!.dir;
  return path.join(dir, `${name}.md`);
}

describe("renameAgentFile", () => {
  it("moves the file, preserves body + frontmatter, and updates name", () => {
    const roots = { home: home() };
    writeAgentFile(roots, "global", "helper", {
      description: "A helpful agent",
      tools: ["read", "grep"],
      body: "You are a helper.",
    });

    renameAgentFile(roots, "global", "helper", "assistant");

    expect(existsSync(globalAgentPath(roots, "helper"))).toBe(false);
    const scanned = scanAgents({ home: roots.home });
    const names = scanned.filter((a) => a.scope === "global").map((a) => a.name);
    expect(names).toContain("assistant");
    expect(names).not.toContain("helper");

    const assistant = scanned.find((a) => a.name === "assistant" && a.scope === "global")!;
    expect(assistant.description).toBe("A helpful agent");
    expect(assistant.tools).toEqual(["read", "grep"]);
    expect(assistant.body).toBe("You are a helper.");
    expect(readFileSync(globalAgentPath(roots, "assistant"), "utf8")).toContain("name: assistant");
  });

  it("throws agent_exists / agent_not_found for a clash or missing source", () => {
    const roots = { home: home() };
    writeAgentFile(roots, "global", "a", { body: "x" });
    writeAgentFile(roots, "global", "b", { body: "y" });
    expect(() => renameAgentFile(roots, "global", "a", "b")).toThrow("agent_exists");
    expect(() => renameAgentFile(roots, "global", "ghost", "z")).toThrow("agent_not_found");
    // The clash left both originals intact.
    const names = scanAgents({ home: roots.home })
      .filter((x) => x.scope === "global")
      .map((x) => x.name)
      .sort();
    expect(names).toEqual(["a", "b"]);
  });

  it("handles a case-only rename on any filesystem", () => {
    const roots = { home: home() };
    writeAgentFile(roots, "global", "helper", { body: "keep" });
    const to = renameAgentFile(roots, "global", "helper", "Helper");
    expect(existsSync(to)).toBe(true);
    const names = scanAgents({ home: roots.home })
      .filter((a) => a.scope === "global")
      .map((a) => a.name);
    expect(names).toEqual(["Helper"]);
  });
});
