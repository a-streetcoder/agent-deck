import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, selectProject, test } from "../helpers/fixtures.ts";
import { startHarness, type E2eHarness } from "../helpers/env.ts";

/**
 * Tier-3 gate (Issues screen): a project's GitHub issues (via the gh CLI,
 * stubbed here for hermeticity) list, and selecting one starts a new session
 * with the composer seeded from the issue.
 */

// The gh CLI is stubbed with a unix shell script for hermeticity; skip on
// Windows (gh runs natively there). The Linux e2e leg covers this feature.
test.skip(process.platform === "win32", "gh CLI stub is a unix shell script");

let harness: E2eHarness;
const project = mkdtempSync(path.join(tmpdir(), "proj-issues-"));

test.beforeAll(async () => {
  // Stub gh so the test needs no network or real repo.
  const stub = path.join(mkdtempSync(path.join(tmpdir(), "gh-stub-")), "gh");
  // Branches on the subcommand: `issue view <n>` returns one issue's detail;
  // `issue list` varies by the --state the server forwards (proves the filter
  // re-queries gh).
  writeFileSync(
    stub,
    `#!/bin/sh
sub="$2"
num="$3"
state=open
while [ $# -gt 0 ]; do case "$1" in --state) shift; state="$1" ;; esac; shift; done
if [ "$sub" = "close" ]; then
exit 0
elif [ "$sub" = "view" ]; then
cat <<JSON
{"number":$num,"title":"Fix the flux capacitor","body":"Steps to reproduce the flux leak.","state":"OPEN","url":"https://github.com/x/y/issues/$num","labels":[{"name":"bug"}],"assignees":[{"login":"marty"}],"author":{"login":"doc"},"comments":[{"author":{"login":"marty"},"body":"Confirmed on my machine too.","createdAt":"2026-02-01T09:30:00Z"}]}
JSON
elif [ "$state" = "closed" ]; then
cat <<'JSON'
[{"number":9,"title":"Old flux leak (fixed)","state":"CLOSED","url":"https://github.com/x/y/issues/9","labels":[]}]
JSON
else
cat <<'JSON'
[{"number":7,"title":"Fix the flux capacitor","state":"OPEN","url":"https://github.com/x/y/issues/7","labels":[{"name":"bug"}],"author":{"login":"doc"},"updatedAt":"2026-02-01T09:30:00Z"}]
JSON
fi
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

test("the All Projects workspace prompts to pick a project", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await page.getByTestId("nav-issues").click();
  await expect(page.getByTestId("issues-no-project")).toBeVisible();
});

test("opens an issue's detail and starts a seeded session from it", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(project));
  await expect(page.getByTestId("session-cwd")).toHaveText(project);
  await page.getByTestId("nav-issues").click();

  const issue = page.getByTestId("issue-7");
  await expect(issue).toBeVisible();
  await expect(issue).toContainText("Fix the flux capacitor");
  await expect(issue).toContainText("bug");
  // The list row shows the author and a relative last-updated time (native meta row).
  await expect(issue.getByTestId("issue-author")).toHaveText("doc");
  // A fixed past updatedAt renders as a relative "N units ago" caption. The
  // formatter uses the runtime's default locale (native-faithful), so assert a
  // digit — present in every locale with numeric:"always" ("5 months ago",
  // "il y a 5 mois", …) — rather than the English word "ago".
  await expect(issue.getByTestId("issue-updated")).toHaveText(/\d/);

  // Clicking opens the detail pane (native GitHubIssueDetailView): body,
  // author, and state all rendered from `gh issue view`.
  await issue.click();
  const detail = page.getByTestId("issue-detail");
  await expect(detail).toBeVisible();
  await expect(page.getByTestId("issue-detail-body")).toContainText("Steps to reproduce");
  await expect(detail).toContainText("doc"); // author
  await expect(page.getByTestId("issue-detail-state")).toHaveText("open");

  // The comments thread (native GitHubIssueDetailView) renders each comment.
  const comment = page.getByTestId("issue-comment");
  await expect(comment).toHaveCount(1);
  await expect(comment).toContainText("Confirmed on my machine too.");
  await expect(comment).toContainText("marty");

  // Close the open issue (native 10.9): the state pill flips and the close
  // actions disappear.
  await expect(page.getByTestId("issue-close-completed")).toBeVisible();
  await page.getByTestId("issue-close-completed").click();
  await expect(page.getByTestId("issue-detail-state")).toHaveText("closed");
  await expect(page.getByTestId("issue-close-completed")).toHaveCount(0);

  // Back returns to the list; re-open and use "Open in Pi" to seed a session.
  await page.getByTestId("issue-detail-back").click();
  await expect(page.getByTestId("issues-list")).toBeVisible();
  await page.getByTestId("issue-7").click();
  await page.getByTestId("issue-open-in-pi").click();
  await expect(page.getByTestId("composer-input")).toHaveValue(/issue #7: Fix the flux capacitor/);
});

test("the Open / Closed filter re-queries gh for the chosen state", async ({ page }) => {
  await page.goto(harness.baseUrl);
  await selectProject(page, path.basename(project));
  await page.getByTestId("nav-issues").click();

  // Defaults to open: the open issue shows, the closed one doesn't.
  await expect(page.getByTestId("issue-7")).toBeVisible();
  await expect(page.getByTestId("issue-9")).toHaveCount(0);

  // Switching to Closed re-fetches with --state closed.
  await page.getByTestId("issues-state-closed").click();
  await expect(page.getByTestId("issue-9")).toContainText("Old flux leak");
  await expect(page.getByTestId("issue-7")).toHaveCount(0);
});
