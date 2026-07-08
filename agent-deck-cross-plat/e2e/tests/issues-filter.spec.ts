import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Issues label + assignee facet filters (native 10.5, AppViewModel.filteredBoardItems):
 * the loaded board is filtered CLIENT-SIDE — labels are multi-select with OR
 * semantics, assignee is single-select — with the facets derived from the loaded
 * issues. The gh CLI is stubbed to return three open issues with distinct
 * labels/assignees so we can drive the chips and assert the visible rows.
 */

// The gh stub is a unix shell script; skip on Windows (gh runs natively there).
test.skip(process.platform === "win32", "gh CLI stub is a unix shell script");

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-issues-filter-"));

test.beforeAll(async () => {
  const stub = path.join(mkdtempSync(path.join(tmpdir(), "gh-stub-")), "gh");
  writeFileSync(
    stub,
    `#!/bin/sh
cat <<'JSON'
[{"number":1,"title":"Fix login crash","state":"OPEN","url":"https://x/1","labels":[{"name":"bug"}],"assignees":[{"login":"marty"}],"author":{"login":"alice"}},
 {"number":2,"title":"Add dark mode","state":"OPEN","url":"https://x/2","labels":[{"name":"feature"}],"assignees":[{"login":"doc"}],"author":{"login":"bob"}},
 {"number":3,"title":"Flaky retry logic","state":"OPEN","url":"https://x/3","labels":[{"name":"bug"},{"name":"flaky"}],"assignees":[{"login":"doc"}],"author":{"login":"alice"}}]
JSON
`,
  );
  chmodSync(stub, 0o755);
  process.env.AGENT_DECK_GH_BIN = stub;

  harness = await startHarness({ chunkDelayMs: 20 });
  const response = await fetch(`${harness.baseUrl}/projects`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ path: project }),
  });
  if (!response.ok) throw new Error(await response.text());
});

test.afterAll(async () => {
  delete process.env.AGENT_DECK_GH_BIN;
  await harness.close();
});

test("label (OR) + assignee facet filters narrow the loaded board client-side", async ({
  page,
}) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  await page.getByTestId("nav-issues").click();

  // All three issues load.
  await expect(page.getByTestId("issue-1")).toBeVisible();
  await expect(page.getByTestId("issue-2")).toBeVisible();
  await expect(page.getByTestId("issue-3")).toBeVisible();

  // Filter by the "bug" label → only #1 and #3 (both carry it), not #2.
  await page.getByTestId("issues-label-bug").click();
  await expect(page.getByTestId("issue-1")).toBeVisible();
  await expect(page.getByTestId("issue-3")).toBeVisible();
  await expect(page.getByTestId("issue-2")).toHaveCount(0);

  // Add the "feature" label → OR semantics widen the set back to include #2.
  await page.getByTestId("issues-label-feature").click();
  await expect(page.getByTestId("issue-1")).toBeVisible();
  await expect(page.getByTestId("issue-2")).toBeVisible();
  await expect(page.getByTestId("issue-3")).toBeVisible();

  // Clear, then filter by assignee "doc" → only #2 and #3.
  await page.getByTestId("issues-clear-filters").click();
  await page.getByTestId("issues-assignee-doc").click();
  await expect(page.getByTestId("issue-2")).toBeVisible();
  await expect(page.getByTestId("issue-3")).toBeVisible();
  await expect(page.getByTestId("issue-1")).toHaveCount(0);

  // Intersect with the "flaky" label → assignee doc AND (label flaky) → only #3.
  await page.getByTestId("issues-label-flaky").click();
  await expect(page.getByTestId("issue-3")).toBeVisible();
  await expect(page.getByTestId("issue-1")).toHaveCount(0);
  await expect(page.getByTestId("issue-2")).toHaveCount(0);

  // A combination that matches nothing shows the filters-active empty state.
  await page.getByTestId("issues-assignee-doc").click(); // now only label flaky
  await page.getByTestId("issues-assignee-marty").click(); // marty has bug, not flaky
  await expect(page.getByTestId("issues-empty")).toContainText("Try clearing the filters");

  // Clearing restores the full board.
  await page.getByTestId("issues-clear-filters").click();
  await expect(page.getByTestId("issue-1")).toBeVisible();
  await expect(page.getByTestId("issue-2")).toBeVisible();
  await expect(page.getByTestId("issue-3")).toBeVisible();
});

test("author (single-select) filter narrows the board and composes with labels", async ({
  page,
}) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  await page.getByTestId("nav-issues").click();
  await expect(page.getByTestId("issue-1")).toBeVisible();

  // Author "alice" wrote #1 and #3.
  await page.getByTestId("issues-author-alice").click();
  await expect(page.getByTestId("issue-1")).toBeVisible();
  await expect(page.getByTestId("issue-3")).toBeVisible();
  await expect(page.getByTestId("issue-2")).toHaveCount(0);

  // Single-select: picking "bob" replaces alice → only #2.
  await page.getByTestId("issues-author-bob").click();
  await expect(page.getByTestId("issue-2")).toBeVisible();
  await expect(page.getByTestId("issue-1")).toHaveCount(0);
  await expect(page.getByTestId("issue-3")).toHaveCount(0);

  // Author bob AND label bug → nothing (bob's #2 is a feature): empty state.
  await page.getByTestId("issues-label-bug").click();
  await expect(page.getByTestId("issues-empty")).toContainText("Try clearing the filters");

  // Clear restores everything.
  await page.getByTestId("issues-clear-filters").click();
  await expect(page.getByTestId("issue-1")).toBeVisible();
  await expect(page.getByTestId("issue-2")).toBeVisible();
  await expect(page.getByTestId("issue-3")).toBeVisible();
});

test("free-text search filters the loaded board over title / #number / label / assignee", async ({
  page,
}) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId(`project-${path.basename(project)}`).click();
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  await page.getByTestId("nav-issues").click();
  await expect(page.getByTestId("issue-1")).toBeVisible();

  // Title substring (case-insensitive) → only #2 "Add dark mode".
  await page.getByTestId("issues-search").fill("DARK");
  await expect(page.getByTestId("issue-2")).toBeVisible();
  await expect(page.getByTestId("issue-1")).toHaveCount(0);
  await expect(page.getByTestId("issue-3")).toHaveCount(0);

  // #number match → only #3.
  await page.getByTestId("issues-search").fill("#3");
  await expect(page.getByTestId("issue-3")).toBeVisible();
  await expect(page.getByTestId("issue-1")).toHaveCount(0);

  // Assignee text → marty is only on #1.
  await page.getByTestId("issues-search").fill("marty");
  await expect(page.getByTestId("issue-1")).toBeVisible();
  await expect(page.getByTestId("issue-2")).toHaveCount(0);

  // Author text is in the haystack → "alice" wrote #1 and #3.
  await page.getByTestId("issues-search").fill("alice");
  await expect(page.getByTestId("issue-1")).toBeVisible();
  await expect(page.getByTestId("issue-3")).toBeVisible();
  await expect(page.getByTestId("issue-2")).toHaveCount(0);

  // Search AND facets compose: label "bug" (→ #1,#3) then search "flaky" (→ #3).
  await page.getByTestId("issues-search").fill("");
  await page.getByTestId("issues-label-bug").click();
  await page.getByTestId("issues-search").fill("flaky");
  await expect(page.getByTestId("issue-3")).toBeVisible();
  await expect(page.getByTestId("issue-1")).toHaveCount(0);

  // No match → the query-specific empty state (native emptyStateMessage).
  await page.getByTestId("issues-search").fill("nonexistent-xyz");
  await expect(page.getByTestId("issues-empty")).toContainText("No issues match");
  await expect(page.getByTestId("issues-empty")).toContainText("nonexistent-xyz");

  // Clearing the search (facet still active) restores the facet's matches.
  await page.getByTestId("issues-search").fill("");
  await expect(page.getByTestId("issue-1")).toBeVisible();
  await expect(page.getByTestId("issue-3")).toBeVisible();
  await expect(page.getByTestId("issue-2")).toHaveCount(0);
});
