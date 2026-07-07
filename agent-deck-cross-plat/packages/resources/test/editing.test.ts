import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { agentMatchesFilter } from "@agent-deck/domain";
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

    // The scanned override flows through to the Agents screen "overridden" chip,
    // while a pristine builtin from the same scan does not.
    expect(agentMatchesFilter(coder, "overridden")).toBe(true);
    const pristine = scanAgents({ home }).find((a) => a.scope === "builtin" && !a.overridden)!;
    expect(agentMatchesFilter(pristine, "overridden")).toBe(false);
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

  it("edits a builtin's mcpServers as a managed override, file untouched, and surfaces it", () => {
    const home = makeHome();
    const builtinFile = path.join(BUILTIN_AGENTS_DIR, "coder.md");
    const bytesBefore = readFileSync(builtinFile);

    // The editor always submits the current mcpServers, so it's diffed like tools.
    const base = scanAgents({ home }).find((a) => a.name === "coder" && a.scope === "builtin")!;
    const override = computeBuiltinOverride(base, { mcpServers: ["github", "linear"] });
    expect(override).toEqual({ mcpServers: ["github", "linear"] });
    writeBuiltinAgentOverride({ home }, "coder", override);

    expect(readFileSync(builtinFile).equals(bytesBefore)).toBe(true);
    const coder = scanAgents({ home }).find((a) => a.name === "coder")!;
    expect(coder.mcpServers).toEqual(["github", "linear"]);

    // Clearing it (empty list submitted) removes the override again.
    const cleared = mergeWithUnmanagedOverrideFields(
      readAgentOverrides({ home }).coder,
      computeBuiltinOverride(base, { mcpServers: [] }),
    );
    writeBuiltinAgentOverride({ home }, "coder", cleared);
    expect(scanAgents({ home }).find((a) => a.name === "coder")!.mcpServers).toBeUndefined();
  });

  it("round-trips an agent's fallbackModels through write + scan (no silent loss)", () => {
    const home = makeHome();
    const project = mkdtempSync(path.join(tmpdir(), "edit-proj-"));
    const roots = { home, projectPath: project };

    const filePath = writeAgentFile(roots, "project", "sequencer", {
      description: "Plans",
      model: "anthropic/claude-opus-4",
      fallbackModels: ["anthropic/claude-sonnet-4", "openai/gpt-4o"],
      body: "You plan.",
    });
    // Serialized comma-joined (native AgentPersistence.swift:339), like mcpServers.
    expect(readFileSync(filePath, "utf8")).toContain(
      "fallbackModels: anthropic/claude-sonnet-4, openai/gpt-4o",
    );

    const agent = scanAgents(roots).find((a) => a.name === "sequencer")!;
    expect(agent.fallbackModels).toEqual(["anthropic/claude-sonnet-4", "openai/gpt-4o"]);

    // A later unrelated edit (the exact silent-loss bug) preserves fallbackModels.
    writeAgentFile(roots, "project", "sequencer", { description: "Plans better" });
    expect(readFileSync(filePath, "utf8")).toContain(
      "fallbackModels: anthropic/claude-sonnet-4, openai/gpt-4o",
    );
    expect(scanAgents(roots).find((a) => a.name === "sequencer")!.fallbackModels).toEqual([
      "anthropic/claude-sonnet-4",
      "openai/gpt-4o",
    ]);

    // Clearing removes the field.
    writeAgentFile(roots, "project", "sequencer", { fallbackModels: [] });
    expect(readFileSync(filePath, "utf8")).not.toContain("fallbackModels:");
    expect(scanAgents(roots).find((a) => a.name === "sequencer")!.fallbackModels).toBeUndefined();
  });

  it("edits a builtin's fallbackModels as a managed override, file untouched", () => {
    const home = makeHome();
    const builtinFile = path.join(BUILTIN_AGENTS_DIR, "coder.md");
    const bytesBefore = readFileSync(builtinFile);

    const base = scanAgents({ home }).find((a) => a.name === "coder" && a.scope === "builtin")!;
    const override = computeBuiltinOverride(base, {
      fallbackModels: ["anthropic/claude-sonnet-4"],
    });
    expect(override).toEqual({ fallbackModels: ["anthropic/claude-sonnet-4"] });
    writeBuiltinAgentOverride({ home }, "coder", override);

    expect(readFileSync(builtinFile).equals(bytesBefore)).toBe(true);
    const coder = scanAgents({ home }).find((a) => a.name === "coder")!;
    expect(coder.fallbackModels).toEqual(["anthropic/claude-sonnet-4"]);

    // Clearing it (empty list submitted) removes the override again.
    const cleared = mergeWithUnmanagedOverrideFields(
      readAgentOverrides({ home }).coder,
      computeBuiltinOverride(base, { fallbackModels: [] }),
    );
    writeBuiltinAgentOverride({ home }, "coder", cleared);
    expect(scanAgents({ home }).find((a) => a.name === "coder")!.fallbackModels).toBeUndefined();
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
