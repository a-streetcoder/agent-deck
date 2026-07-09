import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, selectProject, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Tier-3 gate (Prompts screen): a prompt template created through the screen
 * lands on disk as a .pi/prompts/<name>.md file (pi's /<name> slash command),
 * edits persist, and delete removes it.
 */

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-prompts-"));

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
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

test("create, edit, and delete a project prompt template", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(project));
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  await page.getByTestId("nav-prompts").click();

  // Create.
  await page.getByTestId("prompt-new").click();
  await page.getByTestId("prompt-name").fill("review");
  await page.getByTestId("prompt-description").fill("Review this change");
  await page.getByTestId("prompt-body").fill("Please review the diff for bugs.");
  await page.getByTestId("prompt-save").click();

  const row = page.locator('[data-prompt-name="review"]');
  await expect(row).toBeVisible();
  await expect(row.getByTestId("prompt-invocation")).toHaveText("/review");
  await expect(row.getByTestId("scope-chip")).toHaveAttribute("data-scope", "project");
  // "All Projects" default is a global-only concept — a project prompt has no toggle.
  await expect(row.getByTestId("prompt-default-review")).toHaveCount(0);

  // On disk where pi loads it.
  const file = path.join(project, ".pi", "prompts", "review.md");
  expect(existsSync(file)).toBe(true);
  expect(readFileSync(file, "utf8")).toContain("Please review the diff for bugs.");

  // Edit the body.
  await row.getByTestId("prompt-invocation").click();
  // The editor surfaces the on-disk path (native "File" metadata row); path
  // separators follow the OS, so match the .pi/prompts/review.md suffix.
  await expect(page.getByTestId("prompt-file-path")).toContainText(
    path.join(".pi", "prompts", "review.md"),
  );
  await page.getByTestId("prompt-body").fill("Please review the diff for security issues.");
  await page.getByTestId("prompt-save").click();
  await expect
    .poll(() => readFileSync(file, "utf8"))
    .toContain("Please review the diff for security issues.");

  // Rename review → audit: the file moves on disk, /prompt:<name> follows.
  await row.getByTestId("prompt-rename-review").click();
  await page.getByTestId("prompt-rename-input-review").fill("audit");
  await page.getByTestId("prompt-rename-confirm-review").click();

  const renamed = page.locator('[data-prompt-name="audit"]');
  await expect(renamed.getByTestId("prompt-invocation")).toHaveText("/audit");
  await expect(page.locator('[data-prompt-name="review"]')).toHaveCount(0);
  const auditFile = path.join(project, ".pi", "prompts", "audit.md");
  await expect.poll(() => existsSync(auditFile)).toBe(true);
  expect(existsSync(file)).toBe(false);
  // Body carried across the rename.
  expect(readFileSync(auditFile, "utf8")).toContain("Please review the diff for security issues.");

  // Delete is confirm-gated (native parity): dismissing keeps the prompt.
  page.once("dialog", (dialog) => {
    expect(dialog.message()).toContain(`Delete prompt "audit"`);
    void dialog.dismiss();
  });
  await page.getByTestId("prompt-delete-audit").click();
  await expect(page.locator('[data-prompt-name="audit"]')).toHaveCount(1);
  expect(existsSync(auditFile)).toBe(true);

  // Accepting the confirm actually deletes it (file + row gone).
  page.once("dialog", (dialog) => void dialog.accept());
  await page.getByTestId("prompt-delete-audit").click();
  await expect(page.locator('[data-prompt-name="audit"]')).toHaveCount(0);
  expect(existsSync(auditFile)).toBe(false);
});

test("surfaces the /invocation and argument-hint for a prompt on disk (native 8.1)", async ({
  page,
}) => {
  // Seed a prompt whose FILE basename differs from its frontmatter name (which
  // pi ignores), and that declares an argument-hint.
  const dir = path.join(project, ".pi", "prompts");
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    path.join(dir, "deploy-svc.md"),
    "---\nname: Deploy Service\ndescription: Ship a service\nargument-hint: <service> [env]\n---\n\nDeploy $1 to ${2:-staging}.\n",
  );

  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(project));
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  await page.getByTestId("nav-prompts").click();

  // Identity is the basename (pi ignores the frontmatter name), so the row is
  // keyed by deploy-svc, the command is /deploy-svc, and the argument-hint
  // renders beside it. This also guarantees edit/rename/delete target the real
  // file rather than "Deploy Service.md".
  const row = page.locator('[data-prompt-name="deploy-svc"]');
  await expect(row.getByTestId("prompt-invocation")).toHaveText("/deploy-svc");
  await expect(row.getByTestId("prompt-argument-hint")).toHaveText("<service> [env]");
});

test("the All Projects toggle sets a prompt as a default (native defaultPromptTemplateNames)", async ({
  page,
}) => {
  // Seed a global prompt in the hermetic pi home.
  const dir = path.join(harness.piHome, ".pi", "agent", "prompts");
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    path.join(dir, "changelog-note.md"),
    "---\ndescription: Draft a changelog note\n---\n\nWrite a changelog note.\n",
  );

  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(project));
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  await page.getByTestId("nav-prompts").click();

  const toggle = page.getByTestId("prompt-default-changelog-note");
  await expect(toggle).toBeVisible();
  await expect(toggle).toHaveAttribute("aria-pressed", "false");

  // Enable → the toggle flips and the setting persists server-side.
  await toggle.click();
  await expect(toggle).toHaveAttribute("aria-pressed", "true");
  await expect
    .poll(async () => {
      const { settings } = (await (await fetch(`${harness.baseUrl}/settings`)).json()) as {
        settings: { defaultPromptTemplates?: string[] };
      };
      return settings.defaultPromptTemplates ?? [];
    })
    .toContain("changelog-note");

  // Disable → removed again.
  await toggle.click();
  await expect(toggle).toHaveAttribute("aria-pressed", "false");
  await expect
    .poll(async () => {
      const { settings } = (await (await fetch(`${harness.baseUrl}/settings`)).json()) as {
        settings: { defaultPromptTemplates?: string[] };
      };
      return settings.defaultPromptTemplates ?? [];
    })
    .not.toContain("changelog-note");
});

test("the editor's per-project availability assigns a global prompt to a project (native)", async ({
  page,
}) => {
  const dir = path.join(harness.piHome, ".pi", "agent", "prompts");
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    path.join(dir, "briefing.md"),
    "---\ndescription: Draft a briefing\n---\n\nWrite a briefing.\n",
  );

  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(project));
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  await page.getByTestId("nav-prompts").click();

  // Open the editor for the global prompt, then assign it to this project via
  // the per-project availability checkbox.
  await page.locator('[data-prompt-name="briefing"]').getByTestId("prompt-invocation").click();
  await expect(page.getByTestId("prompt-editor")).toBeVisible();
  const checkbox = page.getByTestId(`prompt-assign-briefing-${path.basename(project)}`);
  await expect(checkbox).not.toBeChecked();
  await checkbox.check();

  await expect
    .poll(async () => {
      const { projects } = (await (await fetch(`${harness.baseUrl}/projects`)).json()) as {
        projects: Array<{ path: string; assignedPrompts?: string[] }>;
      };
      return projects.find((p) => p.path === project)?.assignedPrompts ?? [];
    })
    .toContain("briefing");

  // Uncheck → removed from the project's assignment.
  await checkbox.uncheck();
  await expect
    .poll(async () => {
      const { projects } = (await (await fetch(`${harness.baseUrl}/projects`)).json()) as {
        projects: Array<{ path: string; assignedPrompts?: string[] }>;
      };
      return projects.find((p) => p.path === project)?.assignedPrompts ?? [];
    })
    .not.toContain("briefing");
});
