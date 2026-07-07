import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { agentMatchesFilter } from "@agent-deck/domain";
import { describe, expect, it } from "vitest";
import { scanAgents, scanPrompts, scanSkills } from "../src/scanner.ts";

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

  it("reflects pi's disable-model-invocation frontmatter (native 7.6 detail)", () => {
    const home = makeHome();
    const manual = path.join(home, ".pi", "agent", "skills", "danger-op");
    mkdirSync(manual, { recursive: true });
    writeFileSync(
      path.join(manual, "SKILL.md"),
      "---\nname: danger-op\ndescription: A destructive op\ndisable-model-invocation: true\n---\n\nRun the op.\n",
    );
    const auto = path.join(home, ".pi", "agent", "skills", "helper");
    mkdirSync(auto, { recursive: true });
    writeFileSync(
      path.join(auto, "SKILL.md"),
      "---\nname: helper\ndescription: A helper\n---\n\nHelp.\n",
    );

    const skills = scanSkills({ home });
    expect(skills.find((s) => s.name === "danger-op")!.disableModelInvocation).toBe(true);
    expect(skills.find((s) => s.name === "helper")!.disableModelInvocation).toBe(false);
  });
});

describe("scanPrompts (native prompt.invocation + argument-hint, §8.1)", () => {
  function writePrompt(dir: string, file: string, content: string): void {
    mkdirSync(dir, { recursive: true });
    writeFileSync(path.join(dir, file), content);
  }

  it("derives the invocation from the FILE basename and reads argument-hint", () => {
    const home = makeHome();
    const dir = path.join(home, ".pi", "agent", "prompts");
    writePrompt(
      dir,
      "review.md",
      "---\ndescription: Review a PR\nargument-hint: <pr-number>\n---\n\nReview #$1.\n",
    );

    const prompts = scanPrompts({ home });
    const review = prompts.find((p) => p.name === "review")!;
    expect(review.invocation).toBe("/review");
    expect(review.argumentHint).toBe("<pr-number>");
    expect(review.description).toBe("Review a PR");
  });

  it("identity is the basename — a divergent frontmatter `name` is ignored (matches pi)", () => {
    // pi registers the command under the basename and ignores a frontmatter
    // name, so `name` (which edit/rename/delete + the writer key off as
    // `${name}.md`) must be the basename — otherwise those actions target the
    // wrong file. A hand-authored divergent frontmatter name must not leak in.
    const home = makeHome();
    const dir = path.join(home, ".pi", "agent", "prompts");
    writePrompt(
      dir,
      "ship-it.md",
      "---\nname: Ship It\ndescription: Ship\n---\n\nShip the build.\n",
    );

    const prompt = scanPrompts({ home }).find((p) => p.invocation === "/ship-it")!;
    expect(prompt).toBeDefined();
    expect(prompt.name).toBe("ship-it"); // the basename, NOT "Ship It"
    expect(prompt.invocation).toBe("/ship-it");
  });

  it("leaves argumentHint undefined when there's no argument-hint frontmatter", () => {
    const home = makeHome();
    const dir = path.join(home, ".pi", "agent", "prompts");
    writePrompt(dir, "note.md", "---\ndescription: A note\n---\n\nJust a note.\n");
    expect(scanPrompts({ home }).find((p) => p.name === "note")!.argumentHint).toBeUndefined();
  });
});
