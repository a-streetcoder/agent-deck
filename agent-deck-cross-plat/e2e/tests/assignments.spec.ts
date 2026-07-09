import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, selectProject, test } from "../helpers/fixtures.ts";
import type { SessionMeta } from "@agent-deck/domain";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Slice-10 gate: a skill assigned to a project reaches pi as a --skill flag —
 * verified from pi's own get_commands (`/skill:<name>` appears) — and a
 * project's default agent is auto-selected when switching to it.
 */

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-assign-"));

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });

  // A project skill + a project agent on disk, and the project registered.
  const skillDir = path.join(project, ".pi", "skills", "tidy-commits");
  mkdirSync(skillDir, { recursive: true });
  writeFileSync(
    path.join(skillDir, "SKILL.md"),
    "---\nname: tidy-commits\ndescription: Write tidy commits\n---\n\nHow to write tidy commits.\n",
  );
  const agentsDir = path.join(project, ".pi", "agents");
  mkdirSync(agentsDir, { recursive: true });
  writeFileSync(
    path.join(agentsDir, "syrup-bot.md"),
    "---\nname: syrup-bot\ndescription: Syrup specialist\n---\n\nYou are syrup-bot.\n",
  );
  const response = await fetch(`${harness.baseUrl}/projects`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ path: project }),
  });
  if (!response.ok) throw new Error(await response.text());
});

test.afterAll(async () => {
  await harness.close();
});

async function projectId(): Promise<string> {
  const { projects } = (await (await fetch(`${harness.baseUrl}/projects`)).json()) as {
    projects: Array<{ id: string; path: string }>;
  };
  return projects.find((p) => p.path === project)!.id;
}

test("assigning a skill in the UI injects /skill:<name> into new sessions", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(project));
  await expect(page.getByTestId("session-cwd")).toHaveText(project);

  // Assign via the detail pane's per-project checkbox row.
  await page.getByTestId("nav-skills").click();
  await page.locator('[data-skill-name="tidy-commits"]').click();
  const checkbox = page.getByTestId(`assign-skill-tidy-commits-${path.basename(project)}`);
  await checkbox.check();
  await expect(checkbox).toBeChecked();

  // Assignments apply at session creation: create a fresh parent session for
  // the project via REST and ask pi itself what commands it loaded.
  const id = await projectId();
  const created = await fetch(`${harness.baseUrl}/sessions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ projectId: id }),
  });
  expect(created.status).toBe(201);
  const { session } = (await created.json()) as { session: SessionMeta };

  await expect
    .poll(
      async () => {
        const response = await fetch(`${harness.baseUrl}/sessions/${session.id}/commands`);
        if (!response.ok) return [];
        const { commands } = (await response.json()) as {
          commands: Array<{ name: string; source: string }>;
        };
        return commands.filter((c) => c.source === "skill").map((c) => c.name);
      },
      { timeout: 30_000 },
    )
    .toContain("skill:tidy-commits");
});

test("an All-Projects (default) skill reaches sessions of every project", async ({ page }) => {
  // A GLOBAL skill in the hermetic pi home.
  const globalSkillDir = path.join(harness.piHome, ".pi", "agent", "skills", "sign-offs");
  mkdirSync(globalSkillDir, { recursive: true });
  writeFileSync(
    path.join(globalSkillDir, "SKILL.md"),
    "---\nname: sign-offs\ndescription: Sign every message\n---\n\nHow to sign off.\n",
  );

  await page.goto(harness.baseUrl);
  // Enable it for All Projects from the Skills detail pane (Default context).
  await page.getByTestId("nav-skills").click();
  await page.locator('[data-skill-name="sign-offs"]').click();
  const allProjects = page.getByTestId("assign-skill-all-sign-offs");
  await allProjects.check();
  await expect(allProjects).toBeChecked();

  // A fresh session for the registered project (NOT the default context)
  // must load it: pi's get_commands shows /skill:sign-offs.
  const id = await projectId();
  const created = await fetch(`${harness.baseUrl}/sessions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ projectId: id }),
  });
  expect(created.status).toBe(201);
  const { session } = (await created.json()) as { session: SessionMeta };
  await expect
    .poll(
      async () => {
        const response = await fetch(`${harness.baseUrl}/sessions/${session.id}/commands`);
        if (!response.ok) return [];
        const { commands } = (await response.json()) as {
          commands: Array<{ name: string; source: string }>;
        };
        return commands.filter((c) => c.source === "skill").map((c) => c.name);
      },
      { timeout: 30_000 },
    )
    .toContain("skill:sign-offs");
});

test("an All-Projects (default) prompt template reaches sessions as a /<name> command", async () => {
  // A GLOBAL prompt template in the hermetic pi home (native
  // defaultPromptTemplateNames → --prompt-template launch flags).
  const promptsDir = path.join(harness.piHome, ".pi", "agent", "prompts");
  mkdirSync(promptsDir, { recursive: true });
  writeFileSync(
    path.join(promptsDir, "standup.md"),
    "---\ndescription: Draft a standup update\n---\n\nWrite today's standup.\n",
  );

  // Enable it for All Projects (no UI yet — drive the setting over REST).
  const patched = await fetch(`${harness.baseUrl}/settings`, {
    method: "PATCH",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ setDefaultPromptTemplate: { name: "standup", enabled: true } }),
  });
  expect(patched.status).toBe(200);

  // A fresh session for the registered project must load it: pi's get_commands
  // shows the /standup prompt command (source "prompt", bare name — no prefix).
  const id = await projectId();
  const created = await fetch(`${harness.baseUrl}/sessions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ projectId: id }),
  });
  expect(created.status).toBe(201);
  const { session } = (await created.json()) as { session: SessionMeta };
  await expect
    .poll(
      async () => {
        const response = await fetch(`${harness.baseUrl}/sessions/${session.id}/commands`);
        if (!response.ok) return [];
        const { commands } = (await response.json()) as {
          commands: Array<{ name: string; source: string }>;
        };
        return commands.filter((c) => c.source === "prompt").map((c) => c.name);
      },
      { timeout: 30_000 },
    )
    .toContain("standup");
});

test("a per-project assigned prompt template reaches only that project's sessions", async () => {
  // A GLOBAL prompt in the hermetic pi home, assigned to THIS project (native
  // assignedPromptTemplateNames — unioned with the all-projects defaults).
  const promptsDir = path.join(harness.piHome, ".pi", "agent", "prompts");
  mkdirSync(promptsDir, { recursive: true });
  writeFileSync(
    path.join(promptsDir, "handoff.md"),
    "---\ndescription: Write a handoff note\n---\n\nWrite a handoff note.\n",
  );

  const id = await projectId();
  const patched = await fetch(`${harness.baseUrl}/projects/${id}`, {
    method: "PATCH",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ assignedPrompts: ["handoff"] }),
  });
  expect(patched.status).toBe(200);

  // Guard: "handoff" is purely a PER-PROJECT assignment, not an app-level default,
  // so its presence proves the assignedPrompts path (not defaultPromptTemplates).
  const { settings } = (await (await fetch(`${harness.baseUrl}/settings`)).json()) as {
    settings: { defaultPromptTemplates?: string[] };
  };
  expect(settings.defaultPromptTemplates ?? []).not.toContain("handoff");

  // A fresh session for this project loads it (pi's real get_commands).
  const created = await fetch(`${harness.baseUrl}/sessions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ projectId: id }),
  });
  expect(created.status).toBe(201);
  const { session } = (await created.json()) as { session: SessionMeta };
  await expect
    .poll(
      async () => {
        const response = await fetch(`${harness.baseUrl}/sessions/${session.id}/commands`);
        if (!response.ok) return [];
        const { commands } = (await response.json()) as {
          commands: Array<{ name: string; source: string }>;
        };
        return commands.filter((c) => c.source === "prompt").map((c) => c.name);
      },
      { timeout: 30_000 },
    )
    .toContain("handoff");
});

test("the project default agent is auto-selected on switch", async ({ page }) => {
  const id = await projectId();
  const patched = await fetch(`${harness.baseUrl}/projects/${id}`, {
    method: "PATCH",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ defaultAgentName: "syrup-bot" }),
  });
  expect(patched.status).toBe(200);

  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(project));
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  await expect(page.getByTestId("agent-picker")).toHaveValue("syrup-bot");

  // And the Agents screen shows the star on the default (in the detail pane).
  await page.getByTestId("nav-agents").click();
  await page.locator('[data-agent-name="syrup-bot"]').click();
  await expect(page.getByTestId("default-agent-syrup-bot")).toContainText("project default");
});
