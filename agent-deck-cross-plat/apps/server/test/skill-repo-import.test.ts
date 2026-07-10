import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * Git-imported skill repositories keep a PERSISTENT clone + a provenance record
 * (native ImportedSkillRepository) so the repo can be re-synced later — not the
 * old throwaway clone. Importing a local repo records its clone path, imported
 * skill names, and synced commit, and lists it under /resources/skill-repos.
 */

process.env.AGENT_DECK_TEST = "1";

let server: AgentDeckServer;
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));
const repo = mkdtempSync(path.join(tmpdir(), "skillrepo-"));

function git(args: string[]): void {
  execFileSync("git", args, { cwd: repo, stdio: "ignore" });
}

beforeAll(async () => {
  // A repo with one skill (SKILL.md + an asset).
  git(["init", "-b", "main"]);
  git(["config", "user.email", "t@example.com"]);
  git(["config", "user.name", "Test"]);
  mkdirSync(path.join(repo, "web-scraper"), { recursive: true });
  writeFileSync(
    path.join(repo, "web-scraper", "SKILL.md"),
    "---\nname: web-scraper\ndescription: Scrape web pages\n---\n\nScrape web pages.\n",
  );
  writeFileSync(path.join(repo, "web-scraper", "helper.py"), "print('hi')\n");
  git(["add", "-A"]);
  git(["commit", "-m", "init"]);

  process.env.AGENT_DECK_PI_ENV = JSON.stringify({ HOME: tmpHome, USERPROFILE: tmpHome });
  server = await startServer({ dataDir });
});

afterAll(async () => {
  await server.close();
  delete process.env.AGENT_DECK_PI_ENV;
});

describe("git-imported skill repository provenance", () => {
  it("keeps a persistent clone and records the repo for re-sync", async () => {
    const res = await fetch(`http://127.0.0.1:${server.port}/resources/skills/import-git`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ scope: "global", url: repo }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { imported: string[]; repoId: string };
    expect(body.imported).toContain("web-scraper");
    expect(body.repoId).toBeTruthy();

    // The repo is recorded with its clone path, imported skills, and synced commit.
    const listed = (await (
      await fetch(`http://127.0.0.1:${server.port}/resources/skill-repos`)
    ).json()) as {
      repos: Array<{
        id: string;
        remoteUrl: string;
        skillNames: string[];
        lastSyncedCommit: string;
      }>;
    };
    expect(listed.repos).toHaveLength(1);
    const record = listed.repos[0]!;
    expect(record.id).toBe(body.repoId);
    expect(record.remoteUrl).toBe(repo);
    expect(record.skillNames).toContain("web-scraper");
    expect(record.lastSyncedCommit).toMatch(/^[0-9a-f]{40}$/);

    // The persistent clone survives (the imported skill is also in the catalog).
    expect(existsSync(path.join(dataDir, "skill-repos", record.id))).toBe(true);
    expect(
      existsSync(path.join(tmpHome, ".pi", "agent", "skills", "web-scraper", "SKILL.md")),
    ).toBe(true);
  });
});
