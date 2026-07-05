import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test, type Page } from "@playwright/test";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Stage-K gate (composer parity): the `/` slash panel lists pi's commands and
 * inserts one; the `@` panel lists project files and inserts a path; an image
 * attachment reaches the model as image content.
 */

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-composer-"));

test.beforeAll(async () => {
  harness = await startHarness({ chunkDelayMs: 20 });
  // A skill so pi exposes a /skill:… command, and a file for @-search.
  const skillDir = path.join(project, ".pi", "skills", "deployer");
  mkdirSync(skillDir, { recursive: true });
  writeFileSync(
    path.join(skillDir, "SKILL.md"),
    "---\nname: deployer\ndescription: Deploy the app\n---\n\nHow to deploy.\n",
  );
  writeFileSync(path.join(project, "README-uniquename.md"), "# hi\n");
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

async function openProject(page: Page): Promise<void> {
  await page.goto(harness.baseUrl);
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  // Assign the skill so /skill:deployer is loaded, then a fresh chat picks it up.
  await page.getByTestId("nav-skills").click();
  await page.locator('[data-skill-name="deployer"]').click();
  await page.getByTestId(`assign-skill-deployer-${path.basename(project)}`).check();
  await page.getByTestId("new-chat").click();
}

test("slash panel lists pi commands and inserts one", async ({ page }) => {
  await openProject(page);
  const input = page.getByTestId("composer-input");
  await input.click();
  await input.pressSequentially("/skill:dep");

  const panel = page.getByTestId("slash-panel");
  await expect(panel).toBeVisible({ timeout: 30_000 });
  await expect(panel).toContainText("skill:deployer");
  await page.getByTestId("slash-panel-item-skill:deployer").click();
  await expect(input).toHaveValue("/skill:deployer ");
});

test("@ panel lists project files and inserts a path", async ({ page }) => {
  await openProject(page);
  const input = page.getByTestId("composer-input");
  await input.click();
  await input.pressSequentially("look at @README-unique");

  const panel = page.getByTestId("file-panel");
  await expect(panel).toBeVisible({ timeout: 15_000 });
  await expect(panel).toContainText("README-uniquename.md");
  await page.getByTestId("file-panel-item-README-uniquename.md").click();
  await expect(input).toHaveValue("look at @README-uniquename.md ");
});

test("an attached image reaches the model as image content", async ({ page }) => {
  await openProject(page);

  // A 1x1 transparent PNG.
  const pngBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";
  const requestsBefore = harness.mock.requests.length;

  await page.getByTestId("attach-input").setInputFiles({
    name: "pixel.png",
    mimeType: "image/png",
    buffer: Buffer.from(pngBase64, "base64"),
  });
  await expect(page.getByTestId("attachments")).toBeVisible();

  await page.getByTestId("composer-input").fill("describe this image");
  await page.getByTestId("send-button").click();
  await expect(page.getByTestId("assistant-text").last()).toContainText("image", {
    timeout: 30_000,
  });

  // The model request must carry an image content part.
  const request = harness.mock.requests[requestsBefore];
  expect(request).toBeDefined();
  const serialized = JSON.stringify(request);
  expect(serialized).toContain("image_url");
});
