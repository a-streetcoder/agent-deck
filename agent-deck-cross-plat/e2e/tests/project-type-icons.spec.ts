import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";
let h: E2eHarness;
test.beforeAll(async () => {
  h = await startHarness({ chunkDelayMs: 20 });
});
test.afterAll(async () => {
  await h.close();
});
function makeProj(name: string, marker: string, content: string): string {
  const d = mkdtempSync(path.join(tmpdir(), `proj-${name}-`));
  writeFileSync(path.join(d, marker), content);
  return d;
}
test("renders native project-type icons for detected frameworks", async ({ page }) => {
  const projs = [
    makeProj("rust", "Cargo.toml", "[package]\nname='x'\n"),
    makeProj("go", "go.mod", "module x\n"),
    makeProj("react", "package.json", JSON.stringify({ dependencies: { react: "^18" } })),
    makeProj("python", "pyproject.toml", "[project]\nname='x'\n"),
  ];
  for (const p of projs) {
    await fetch(`${h.baseUrl}/projects`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path: p }),
    });
  }
  await page.goto(h.baseUrl);
  await page.getByTestId("nav-projects").click();
  await expect(page.getByTestId("project-type-icon-rust").first()).toBeVisible();
  await expect(page.getByTestId("project-type-icon-go").first()).toBeVisible();
  await expect(page.getByTestId("project-type-icon-react").first()).toBeVisible();
  await expect(page.getByTestId("project-type-icon-python").first()).toBeVisible();
});
