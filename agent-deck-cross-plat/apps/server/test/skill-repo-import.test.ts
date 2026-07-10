import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
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

  const skillMd = path.join(tmpHome, ".pi", "agent", "skills", "web-scraper", "SKILL.md");

  async function repoId(): Promise<string> {
    const { repos } = (await (
      await fetch(`http://127.0.0.1:${server.port}/resources/skill-repos`)
    ).json()) as { repos: Array<{ id: string }> };
    return repos[0]!.id;
  }

  it("detects an upstream change and pulls it into the catalog on update", async () => {
    const id = await repoId();

    // Upstream advances: the skill body changes.
    writeFileSync(
      path.join(repo, "web-scraper", "SKILL.md"),
      "---\nname: web-scraper\ndescription: Scrape web pages\n---\n\nScrape web pages FASTER.\n",
    );
    git(["commit", "-am", "faster"]);

    // check → an update is available.
    const check = (await (
      await fetch(`http://127.0.0.1:${server.port}/resources/skill-repos/${id}/check`, {
        method: "POST",
      })
    ).json()) as { updateAvailable: boolean; remoteCommit: string; syncedCommit: string };
    expect(check.updateAvailable).toBe(true);
    expect(check.remoteCommit).not.toBe(check.syncedCommit);

    // update → the catalog copy reflects the upstream change.
    const upd = await fetch(`http://127.0.0.1:${server.port}/resources/skill-repos/${id}/update`, {
      method: "POST",
    });
    expect(upd.status).toBe(200);
    const { updated } = (await upd.json()) as { updated: boolean };
    expect(updated).toBe(true);
    expect(readFileSync(skillMd, "utf8")).toContain("FASTER");

    // A second check is now up to date.
    const check2 = (await (
      await fetch(`http://127.0.0.1:${server.port}/resources/skill-repos/${id}/check`, {
        method: "POST",
      })
    ).json()) as { updateAvailable: boolean };
    expect(check2.updateAvailable).toBe(false);
  });

  it("removes an upstream-deleted skill from the catalog on update", async () => {
    const id = await repoId();
    const helperDir = path.join(tmpHome, ".pi", "agent", "skills", "second-skill");

    // Upstream ADDS a second skill; update pulls it into the catalog.
    mkdirSync(path.join(repo, "second-skill"), { recursive: true });
    writeFileSync(
      path.join(repo, "second-skill", "SKILL.md"),
      "---\nname: second-skill\ndescription: Second\n---\n\nSecond skill.\n",
    );
    git(["add", "-A"]);
    git(["commit", "-m", "add second"]);
    await fetch(`http://127.0.0.1:${server.port}/resources/skill-repos/${id}/update`, {
      method: "POST",
    });
    expect(existsSync(helperDir)).toBe(true);

    // Upstream REMOVES it; the next update deletes it from the catalog + record.
    execFileSync("git", ["rm", "-r", "second-skill"], { cwd: repo, stdio: "ignore" });
    git(["commit", "-m", "drop second"]);
    await fetch(`http://127.0.0.1:${server.port}/resources/skill-repos/${id}/update`, {
      method: "POST",
    });
    expect(existsSync(helperDir)).toBe(false);
    const { repos } = (await (
      await fetch(`http://127.0.0.1:${server.port}/resources/skill-repos`)
    ).json()) as { repos: Array<{ skillNames: string[] }> };
    expect(repos[0]!.skillNames).not.toContain("second-skill");
  });

  it("holds a locally-edited skill as a conflict and resolves it Take-Remote", async () => {
    const id = await repoId();

    // The user locally edits the catalog copy…
    writeFileSync(
      skillMd,
      "---\nname: web-scraper\ndescription: Scrape web pages\n---\n\nMY LOCAL VERSION.\n",
    );
    // …and upstream also changes the same skill.
    writeFileSync(
      path.join(repo, "web-scraper", "SKILL.md"),
      "---\nname: web-scraper\ndescription: Scrape web pages\n---\n\nUPSTREAM V2.\n",
    );
    git(["commit", "-am", "upstream v2"]);

    // Update HOLDS the edited skill (doesn't silently overwrite the local edit).
    const upd = (await (
      await fetch(`http://127.0.0.1:${server.port}/resources/skill-repos/${id}/update`, {
        method: "POST",
      })
    ).json()) as { updated: boolean; conflicts: string[] };
    expect(upd.conflicts).toContain("web-scraper");
    expect(readFileSync(skillMd, "utf8")).toContain("MY LOCAL VERSION"); // kept

    // Resolve Take-Remote → the upstream version wins.
    const res = await fetch(`http://127.0.0.1:${server.port}/resources/skill-repos/${id}/resolve`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: "web-scraper", resolution: "remote" }),
    });
    expect(res.status).toBe(200);
    expect(readFileSync(skillMd, "utf8")).toContain("UPSTREAM V2");
  });

  it("forgets a repo: drops the record + clone but keeps the imported skill", async () => {
    const id = await repoId();
    const clone = path.join(dataDir, "skill-repos", id);
    const del = await fetch(`http://127.0.0.1:${server.port}/resources/skill-repos/${id}`, {
      method: "DELETE",
    });
    expect(del.status).toBe(200);

    const { repos } = (await (
      await fetch(`http://127.0.0.1:${server.port}/resources/skill-repos`)
    ).json()) as { repos: unknown[] };
    expect(repos).toHaveLength(0); // record gone
    expect(existsSync(clone)).toBe(false); // clone removed
    expect(existsSync(skillMd)).toBe(true); // the copied skill stays in the catalog
  });
});
