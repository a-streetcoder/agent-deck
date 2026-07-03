import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { agentMatchesFilter } from "@agent-deck/domain";
import { describe, expect, it } from "vitest";
import { scanAgents, scanSkills } from "../src/scanner.ts";

function makeHome(): string {
  return mkdtempSync(path.join(tmpdir(), "res-home-"));
}

function makeProject(): string {
  return mkdtempSync(path.join(tmpdir(), "res-proj-"));
}

function writeAgent(dir: string, name: string, frontmatter = ""): void {
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    path.join(dir, `${name}.md`),
    `---\nname: ${name}\ndescription: test agent ${name}\n${frontmatter}---\n\nYou are ${name}.\n`,
  );
}

describe("scanAgents", () => {
  it("always includes the bundled builtin agents", () => {
    const agents = scanAgents({ home: makeHome() });
    const names = agents.filter((a) => a.scope === "builtin").map((a) => a.name);
    expect(names).toEqual(expect.arrayContaining(["coder", "explorer", "planner", "reviewer"]));
  });

  it("scans global and project catalogs with correct scopes", () => {
    const home = makeHome();
    const project = makeProject();
    writeAgent(path.join(home, ".pi", "agent", "agents"), "globby");
    writeAgent(path.join(project, ".pi", "agents"), "projy");
    const agents = scanAgents({ home, projectPath: project });
    expect(agents.find((a) => a.name === "globby")).toMatchObject({ scope: "global" });
    expect(agents.find((a) => a.name === "projy")).toMatchObject({ scope: "project" });
  });

  it("parses comma-separated tools and marks shadowing (project > builtin)", () => {
    const home = makeHome();
    const project = makeProject();
    writeAgent(path.join(project, ".pi", "agents"), "reviewer", "tools: read, grep\n");
    const agents = scanAgents({ home, projectPath: project });
    const projectReviewer = agents.find((a) => a.name === "reviewer" && a.scope === "project")!;
    const builtinReviewer = agents.find((a) => a.name === "reviewer" && a.scope === "builtin")!;
    expect(projectReviewer.tools).toEqual(["read", "grep"]);
    expect(projectReviewer.shadowed).toBe(false);
    expect(projectReviewer.replacesBuiltin).toBe(true);
    expect(builtinReviewer.shadowed).toBe(true);
    // Filter semantics: "replaced" surfaces both sides of the shadowing.
    expect(agentMatchesFilter(projectReviewer, "replaced")).toBe(true);
    expect(agentMatchesFilter(builtinReviewer, "replaced")).toBe(true);
    expect(agentMatchesFilter(projectReviewer, "custom")).toBe(true);
    expect(agentMatchesFilter(builtinReviewer, "custom")).toBe(false);
  });
});

describe("scanSkills", () => {
  it("discovers SKILL.md skills in global and project scopes via pi's loader", () => {
    const home = makeHome();
    const project = makeProject();
    const globalSkill = path.join(home, ".pi", "agent", "skills", "web-research");
    mkdirSync(globalSkill, { recursive: true });
    writeFileSync(
      path.join(globalSkill, "SKILL.md"),
      "---\nname: web-research\ndescription: Research the web\n---\n\nHow to research.\n",
    );
    const projectSkill = path.join(project, ".pi", "skills", "deploy");
    mkdirSync(projectSkill, { recursive: true });
    writeFileSync(
      path.join(projectSkill, "SKILL.md"),
      "---\nname: deploy\ndescription: Deploy this project\n---\n\nHow to deploy.\n",
    );
    const skills = scanSkills({ home, projectPath: project });
    expect(skills.find((s) => s.name === "web-research")).toMatchObject({ scope: "global" });
    expect(skills.find((s) => s.name === "deploy")).toMatchObject({ scope: "project" });
  });
});
