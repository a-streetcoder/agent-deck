import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  existsSync,
  lstatSync,
  readFileSync,
  realpathSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import nodePath from "node:path";
import { promisify } from "node:util";
import type { ProjectMeta } from "@agent-deck/domain";
import { detectProjectType, discoverProjects } from "@agent-deck/resources";
import { z } from "zod";
import type { ServerContext } from "../context.ts";
import {
  INSTRUCTIONS_MAX,
  RESOURCE_NAME,
  instructionsBody,
  resolveInstructionsFile,
} from "./shared.ts";

const createProjectBody = z.object({
  path: z.string(),
  name: z.string().optional(),
});

const patchProjectBody = z.object({
  assignedSkills: z.array(RESOURCE_NAME).optional(),
  assignedPrompts: z.array(RESOURCE_NAME).optional(),
  defaultAgentName: RESOURCE_NAME.nullable().optional(),
  enabled: z.boolean().optional(),
});

/**
 * Project registry routes — list/add/patch/hide, discovery roots + scan,
 * project instructions, and the GitHub issues screens. Moved verbatim from
 * server.ts.
 */
export function registerProjectRoutes(ctx: ServerContext): void {
  const { fastify, projects, sessions, settings, watchProject } = ctx;

  fastify.get("/projects", async () => ({
    projects: projects.list().filter((p) => !p.hidden),
  }));

  // Root folders that are too broad to scan (filesystem/system roots) — a
  // huge fan-out would block the sync scan. Users add specific dev folders.
  const FORBIDDEN_ROOTS = new Set(
    [
      "/",
      "/etc",
      "/usr",
      "/bin",
      "/sbin",
      "/var",
      "/sys",
      "/proc",
      "/dev",
      "/System",
      "/Library",
      "/private",
      homedir(), // the bare home dir fans out enormously; a subfolder is fine
    ].map((p) => nodePath.resolve(p)),
  );

  const canonicalPath = (p: string): string => {
    try {
      return realpathSync.native(p);
    } catch {
      return nodePath.resolve(p);
    }
  };

  // Discovery roots + scan. GET returns the configured roots and every
  // project candidate found under them (flagged if already registered).
  fastify.get("/projects/discovery", async () => {
    const roots = settings.get().projectRoots;
    const known = new Set(projects.list().map((p) => canonicalPath(p.path)));
    const discovered = discoverProjects(roots).map((c) => ({
      ...c,
      registered: known.has(canonicalPath(c.path)),
    }));
    return { roots, discovered };
  });

  fastify.post("/projects/discovery/roots", async (request, reply) => {
    const parsed = z.object({ root: z.string().min(1) }).safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const root = nodePath.resolve(parsed.data.root);
    if (!existsSync(root) || !statSync(root).isDirectory()) {
      return reply.status(400).send({ error: `not a directory: ${root}` });
    }
    if (FORBIDDEN_ROOTS.has(root) || nodePath.dirname(root) === root) {
      return reply.status(400).send({ error: "root is too broad to scan; pick a project folder" });
    }
    return { roots: settings.setProjectRoot(root, true).projectRoots };
  });

  fastify.delete("/projects/discovery/roots", async (request, reply) => {
    const parsed = z.object({ root: z.string().min(1) }).safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    return {
      roots: settings.setProjectRoot(nodePath.resolve(parsed.data.root), false).projectRoots,
    };
  });

  fastify.post("/projects", async (request, reply) => {
    const parsed = createProjectBody.safeParse(request.body);
    if (!parsed.success) {
      return reply.status(400).send({ error: parsed.error.message });
    }
    const projectPath = nodePath.resolve(parsed.data.path);
    if (!existsSync(projectPath) || !statSync(projectPath).isDirectory()) {
      return reply.status(400).send({ error: `not a directory: ${projectPath}` });
    }
    // Idempotent by path: re-adding an existing (possibly hidden) project
    // returns it with its metadata intact — hide is never data loss.
    const existing = projects.find((p) => p.path === projectPath);
    if (existing) {
      if (existing.hidden) {
        const restored = { ...existing, hidden: false };
        projects.upsert(restored);
        return reply.status(200).send({ project: restored });
      }
      return reply.status(200).send({ project: existing });
    }
    const project: ProjectMeta = {
      id: randomUUID(),
      path: projectPath,
      name: parsed.data.name ?? nodePath.basename(projectPath),
      type: detectProjectType(projectPath),
      createdAt: new Date().toISOString(),
    };
    projects.upsert(project);
    watchProject(project.path);
    return reply.status(201).send({ project });
  });

  fastify.patch("/projects/:id", async (request, reply) => {
    const parsed = patchProjectBody.safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { id } = request.params as { id: string };
    const project = projects.find((p) => p.id === id);
    if (!project) return reply.status(404).send({ error: "unknown project" });
    const next: ProjectMeta = { ...project };
    if (parsed.data.assignedSkills !== undefined) next.assignedSkills = parsed.data.assignedSkills;
    if (parsed.data.assignedPrompts !== undefined)
      next.assignedPrompts = parsed.data.assignedPrompts;
    if (parsed.data.defaultAgentName !== undefined) {
      next.defaultAgentName = parsed.data.defaultAgentName ?? undefined;
    }
    if (parsed.data.enabled !== undefined) next.enabled = parsed.data.enabled;
    projects.upsert(next);
    return { project: next };
  });

  // "Hide from list" (native): soft-hide — metadata and session links are
  // preserved and re-adding the same path restores them. The project hosting
  // a LIVE session can't be hidden.
  fastify.delete("/projects/:id", async (request, reply) => {
    const { id } = request.params as { id: string };
    const project = projects.find((p) => p.id === id);
    if (!project) return reply.status(404).send({ error: "unknown project" });
    const hasLiveSession = sessions.list().some((s) => s.projectId === id && !s.endedAt);
    if (hasLiveSession) {
      return reply.status(409).send({ error: "project has a live session" });
    }
    projects.upsert({ ...project, hidden: true });
    return { ok: true };
  });

  const agentsFileFor = (id: string): { path: string } | null => {
    const project = projects.find((p) => p.id === id);
    return project ? { path: resolveInstructionsFile(project.path) } : null;
  };

  fastify.get("/projects/:id/instructions", async (request, reply) => {
    const target = agentsFileFor((request.params as { id: string }).id);
    if (!target) return reply.status(404).send({ error: "unknown project" });
    let content = "";
    if (existsSync(target.path)) {
      if (statSync(target.path).size > INSTRUCTIONS_MAX) {
        return reply.status(413).send({ error: "the instructions file is too large to edit here" });
      }
      content = readFileSync(target.path, "utf8");
    }
    return { content, path: target.path };
  });

  fastify.put("/projects/:id/instructions", async (request, reply) => {
    const target = agentsFileFor((request.params as { id: string }).id);
    if (!target) return reply.status(404).send({ error: "unknown project" });
    const parsed = instructionsBody.safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    // Never write THROUGH a symlink — a symlinked AGENTS.md could redirect the
    // write to a file outside the project.
    if (existsSync(target.path) && lstatSync(target.path).isSymbolicLink()) {
      return reply
        .status(400)
        .send({ error: "the instructions file is a symlink; refusing to write" });
    }
    writeFileSync(target.path, parsed.data.content, "utf8");
    return { ok: true, path: target.path };
  });

  // GitHub issues for a project, via the gh CLI (reuses the user's gh auth so
  // there's no OAuth to build). AGENT_DECK_GH_BIN overrides the binary (tests).
  const execFileAsync = promisify(execFile);
  fastify.get("/projects/:id/issues", async (request, reply) => {
    const project = projects.find((p) => p.id === (request.params as { id: string }).id);
    if (!project) return reply.status(404).send({ error: "unknown project" });
    // Filter by issue state (native Issues screen's Open / Closed / All segmented control).
    const stateParsed = z
      .enum(["open", "closed", "all"])
      .default("open")
      .safeParse((request.query as { state?: string }).state);
    if (!stateParsed.success) return reply.status(400).send({ error: "invalid state filter" });
    const ghBin = process.env.AGENT_DECK_GH_BIN || "gh";
    try {
      const { stdout } = await execFileAsync(
        ghBin,
        [
          "issue",
          "list",
          "--state",
          stateParsed.data,
          "--json",
          // assignees/author are included so the Issues screen can offer the
          // native client-side assignee + author facet filters (native
          // filteredBoardItems) and search over the already-loaded board
          // without a per-filter re-query.
          "number,title,state,url,labels,assignees,author,updatedAt",
          "--limit",
          "50",
        ],
        { cwd: project.path, timeout: 15_000, maxBuffer: 8_000_000 },
      );
      const raw = JSON.parse(stdout) as Array<{
        number: number;
        title: string;
        state: string;
        url: string;
        labels?: Array<{ name: string }>;
        assignees?: Array<{ login: string }>;
        author?: { login: string } | null;
        updatedAt?: string;
      }>;
      return {
        issues: raw.map((i) => ({
          number: i.number,
          title: i.title,
          state: i.state,
          url: i.url,
          labels: (i.labels ?? []).map((l) => l.name),
          assignees: (i.assignees ?? []).map((a) => a.login),
          author: i.author?.login ?? null,
          updatedAt: i.updatedAt ?? null,
        })),
      };
    } catch {
      return {
        issues: [],
        error:
          "Couldn't list issues — needs the gh CLI installed, authenticated, and a GitHub remote.",
      };
    }
  });

  // A single issue's detail (native GitHubIssueDetailView 10.6): title + state +
  // labels + assignees + author + Markdown body, for the detail pane.
  fastify.get("/projects/:id/issues/:number", async (request, reply) => {
    const { id, number } = request.params as { id: string; number: string };
    const project = projects.find((p) => p.id === id);
    if (!project) return reply.status(404).send({ error: "unknown project" });
    if (!/^\d+$/.test(number)) return reply.status(400).send({ error: "invalid issue number" });
    const ghBin = process.env.AGENT_DECK_GH_BIN || "gh";
    try {
      const { stdout } = await execFileAsync(
        ghBin,
        [
          "issue",
          "view",
          number,
          "--json",
          "number,title,body,state,url,labels,assignees,author,comments",
        ],
        { cwd: project.path, timeout: 15_000, maxBuffer: 8_000_000 },
      );
      const raw = JSON.parse(stdout) as {
        number: number;
        title: string;
        body?: string;
        state: string;
        url: string;
        labels?: Array<{ name: string }>;
        assignees?: Array<{ login: string }>;
        author?: { login: string };
        comments?: Array<{ author?: { login: string }; body?: string; createdAt?: string }>;
      };
      return {
        issue: {
          number: raw.number,
          title: raw.title,
          body: raw.body ?? "",
          state: raw.state,
          url: raw.url,
          labels: (raw.labels ?? []).map((l) => l.name),
          assignees: (raw.assignees ?? []).map((a) => a.login),
          author: raw.author?.login ?? null,
          comments: (raw.comments ?? []).map((c) => ({
            author: c.author?.login ?? null,
            body: c.body ?? "",
            createdAt: c.createdAt ?? null,
          })),
        },
      };
    } catch {
      return reply.status(502).send({
        error: "Couldn't load the issue — needs the gh CLI installed, authenticated, and a remote.",
      });
    }
  });

  // Close an issue (native Issues close split-button 10.9): completed or not
  // planned. `gh issue close <n> --reason <reason>`.
  fastify.post("/projects/:id/issues/:number/close", async (request, reply) => {
    const { id, number } = request.params as { id: string; number: string };
    const project = projects.find((p) => p.id === id);
    if (!project) return reply.status(404).send({ error: "unknown project" });
    if (!/^\d+$/.test(number)) return reply.status(400).send({ error: "invalid issue number" });
    const parsed = z
      .object({ reason: z.enum(["completed", "not_planned"]) })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: "invalid close reason" });
    // gh spells the reason with a space; our API uses a snake_case enum.
    const ghReason = parsed.data.reason === "completed" ? "completed" : "not planned";
    const ghBin = process.env.AGENT_DECK_GH_BIN || "gh";
    try {
      await execFileAsync(ghBin, ["issue", "close", number, "--reason", ghReason], {
        cwd: project.path,
        timeout: 15_000,
        maxBuffer: 8_000_000,
      });
    } catch {
      return reply.status(502).send({
        error:
          "Couldn't close the issue — needs the gh CLI installed, authenticated, and a remote.",
      });
    }
    return { ok: true };
  });
}
