import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "@playwright/test";
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
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await expect(page.getByTestId("session-cwd")).toHaveText(project);

  // Assign via the Skills screen checkbox.
  await page.getByTestId("nav-skills").click();
  const checkbox = page.getByTestId("assign-skill-tidy-commits");
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

test("the project default agent is auto-selected on switch", async ({ page }) => {
  const id = await projectId();
  const patched = await fetch(`${harness.baseUrl}/projects/${id}`, {
    method: "PATCH",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ defaultAgentName: "syrup-bot" }),
  });
  expect(patched.status).toBe(200);

  await page.goto(harness.baseUrl);
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  await expect(page.getByTestId("agent-picker")).toHaveValue("syrup-bot");

  // And the Agents screen shows the star on the default.
  await page.getByTestId("nav-agents").click();
  await expect(page.getByTestId("default-agent-syrup-bot")).toContainText("project default");
});
