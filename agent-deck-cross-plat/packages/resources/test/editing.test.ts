import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { BUILTIN_AGENTS_DIR } from "../src/paths.ts";
import {
  computeBuiltinOverride,
  mergeWithUnmanagedOverrideFields,
  readAgentOverrides,
  writeBuiltinAgentOverride,
} from "../src/overrides.ts";
import { scanAgents } from "../src/scanner.ts";
import { writeAgentFile, writeSkillFile } from "../src/writer.ts";

function makeHome(): string {
  return mkdtempSync(path.join(tmpdir(), "edit-home-"));
}

describe("builtin override edit safety", () => {
  it("editing a builtin never touches the builtin file; override applies in scans", () => {
    const home = makeHome();
    const builtinFile = path.join(BUILTIN_AGENTS_DIR, "coder.md");
    const bytesBefore = readFileSync(builtinFile);

    const base = scanAgents({ home }).find((a) => a.name === "coder" && a.scope === "builtin")!;
    const override = computeBuiltinOverride(base, {
      description: "My customized coder",
      tools: ["read", "grep"],
    });
    expect(override).toEqual({ description: "My customized coder", tools: ["read", "grep"] });
    writeBuiltinAgentOverride({ home }, "coder", override);

    // THE guarantee: builtin file bytes are identical.
    expect(readFileSync(builtinFile).equals(bytesBefore)).toBe(true);

    const coder = scanAgents({ home }).find((a) => a.name === "coder")!;
    expect(coder).toMatchObject({
      scope: "builtin",
      overridden: true,
      description: "My customized coder",
      tools: ["read", "grep"],
    });
    // Body untouched by this override.
    expect(coder.body).toBe(base.body);
  });

  it("preserves unknown settings.json keys and prunes empty overrides", () => {
    const home = makeHome();
    const settingsFile = path.join(home, ".pi", "agent", "settings.json");
    mkdirSync(path.dirname(settingsFile), { recursive: true });
    writeFileSync(
      settingsFile,
      JSON.stringify({ theme: "dark", subagents: { disableBuiltins: false } }, null, 2),
    );

    writeBuiltinAgentOverride({ home }, "coder", { description: "x" });
    let settings = JSON.parse(readFileSync(settingsFile, "utf8")) as Record<string, unknown>;
    expect(settings.theme).toBe("dark");
    expect(settings.subagents).toMatchObject({
      disableBuiltins: false,
      agentOverrides: { coder: { description: "x" } },
    });

    // Removing the override prunes agentOverrides but keeps sibling keys.
    writeBuiltinAgentOverride({ home }, "coder", null);
    settings = JSON.parse(readFileSync(settingsFile, "utf8")) as Record<string, unknown>;
    expect(settings.theme).toBe("dark");
    expect(settings.subagents).toEqual({ disableBuiltins: false });
  });

  it("refuses to overwrite an existing but malformed settings.json (data-loss guard)", () => {
    const home = makeHome();
    const settingsFile = path.join(home, ".pi", "agent", "settings.json");
    mkdirSync(path.dirname(settingsFile), { recursive: true });
    writeFileSync(settingsFile, "{ this is not json");
    expect(() => writeBuiltinAgentOverride({ home }, "coder", { description: "x" })).toThrow();
    // The broken file is untouched for the user to repair.
    expect(readFileSync(settingsFile, "utf8")).toBe("{ this is not json");
  });

  it("diffing equal values yields no override; body edits become systemPrompt", () => {
    const home = makeHome();
    const base = scanAgents({ home }).find((a) => a.name === "coder" && a.scope === "builtin")!;
    expect(computeBuiltinOverride(base, { description: base.description })).toBeNull();
    const withBody = computeBuiltinOverride(base, { body: "New prompt." });
    expect(withBody).toEqual({ systemPrompt: "New prompt." });
  });
});

describe("agent/skill file writer", () => {
  it("creates and round-trips a project agent, preserving unknown frontmatter", () => {
    const home = makeHome();
    const project = mkdtempSync(path.join(tmpdir(), "edit-proj-"));
    const roots = { home, projectPath: project };

    const filePath = writeAgentFile(roots, "project", "helper", {
      description: "Helps out",
      tools: ["read"],
      body: "You are helper.",
    });
    // Inject an unknown field as an external tool would.
    const withUnknown = readFileSync(filePath, "utf8").replace(
      "---\n\n",
      "customField: keep-me\n---\n\n",
    );
    writeFileSync(filePath, withUnknown);

    writeAgentFile(roots, "project", "helper", { description: "Helps out more" });
    const content = readFileSync(filePath, "utf8");
    expect(content).toContain("customField: keep-me");
    expect(content).toContain("Helps out more");
    expect(content).toContain("You are helper.");

    const helper = scanAgents(roots).find((a) => a.name === "helper")!;
    expect(helper).toMatchObject({
      scope: "project",
      description: "Helps out more",
      tools: ["read"],
      body: "You are helper.",
    });
  });

  it("round-trips an agent's declared mcpServers through write + scan", () => {
    const home = makeHome();
    const project = mkdtempSync(path.join(tmpdir(), "edit-proj-"));
    const roots = { home, projectPath: project };

    const filePath = writeAgentFile(roots, "project", "researcher", {
      description: "Researches",
      mcpServers: ["github", "linear"],
      body: "You research.",
    });
    // Serialized to frontmatter as a comma list.
    expect(readFileSync(filePath, "utf8")).toContain("mcpServers: github, linear");

    const agent = scanAgents(roots).find((a) => a.name === "researcher")!;
    expect(agent.mcpServers).toEqual(["github", "linear"]);

    // Clearing removes the field.
    writeAgentFile(roots, "project", "researcher", { mcpServers: [] });
    expect(readFileSync(filePath, "utf8")).not.toContain("mcpServers:");
    expect(scanAgents(roots).find((a) => a.name === "researcher")!.mcpServers).toBeUndefined();
  });

  it("surfaces a builtin's mcpServers override and preserves it across an edit (unmanaged)", () => {
    const home = makeHome();
    // An external / native writer set an mcpServers override for a builtin.
    writeBuiltinAgentOverride({ home }, "coder", { mcpServers: ["github"] });
    expect(scanAgents({ home }).find((a) => a.name === "coder")!.mcpServers).toEqual(["github"]);

    // Editing a MANAGED field (description) must not drop the unmanaged mcpServers.
    const base = scanAgents({ home }).find((a) => a.name === "coder" && a.scope === "builtin")!;
    const merged = mergeWithUnmanagedOverrideFields(
      readAgentOverrides({ home }).coder,
      computeBuiltinOverride(base, { description: "Edited coder" }),
    );
    writeBuiltinAgentOverride({ home }, "coder", merged);

    const coder = scanAgents({ home }).find((a) => a.name === "coder")!;
    expect(coder.mcpServers).toEqual(["github"]);
    expect(coder.description).toBe("Edited coder");
  });

  it("creates a skill SKILL.md discoverable by pi's loader", () => {
    const home = makeHome();
    const filePath = writeSkillFile({ home }, "global", "notes", {
      description: "Take notes",
      body: "How to take notes.",
    });
    expect(filePath.endsWith(path.join("notes", "SKILL.md"))).toBe(true);
    expect(readFileSync(filePath, "utf8")).toContain("description: Take notes");
  });
});
