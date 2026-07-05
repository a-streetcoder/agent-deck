import { randomUUID } from "node:crypto";
import { existsSync, readFileSync, realpathSync, rmSync, statSync } from "node:fs";
import type { IncomingMessage } from "node:http";
import { homedir } from "node:os";
import nodePath from "node:path";
import {
  clientMessageSchema,
  type ProjectMeta,
  type ServerMessage,
  type SkillInfo,
} from "@agent-deck/domain";
import {
  computeBuiltinOverride,
  ensureDirs,
  mergeWithUnmanagedOverrideFields,
  parseAgentFile,
  projectWatchDirs,
  readAgentOverrides,
  scanAgents,
  scanSkills,
  watchResources,
  writeAgentFile,
  writeBuiltinAgentOverride,
  writeSkillFile,
  deleteAgentFile,
  setAgentDisabledFile,
  deleteSkillDir,
  scanEnv,
  writeEnvVar,
  discoverProjects,
  detectProjectType,
  listProjectFiles,
  BUILTIN_AGENTS_DIR,
  type ResourceRoots,
} from "@agent-deck/resources";
import { runDoctor } from "@agent-deck/pi-host";
import fastifyStatic from "@fastify/static";
import Fastify, { type FastifyInstance } from "fastify";
import { WebSocketServer, type WebSocket } from "ws";
import { z } from "zod";
import { ProjectIndex, SessionIndex, SettingsStore } from "./persistence.ts";
import { ReceiptBus } from "./receipts.ts";
import {
  SessionManager,
  type AgentSessionPlan,
  type LaunchPlan,
  type ManagedSession,
} from "./SessionManager.ts";

/** Resource names become file/dir names — never let them traverse paths. */
const RESOURCE_NAME = z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._-]*$/, "invalid resource name");

const createProjectBody = z.object({
  path: z.string(),
  name: z.string().optional(),
});

const patchProjectBody = z.object({
  assignedSkills: z.array(RESOURCE_NAME).optional(),
  defaultAgentName: RESOURCE_NAME.nullable().optional(),
  enabled: z.boolean().optional(),
});

const createSessionBody = z.object({
  cwd: z.string().optional(),
  projectId: z.string().optional(),
  /** Launch an agent-backed session: inject this agent's system prompt/tools/skills. */
  agentName: z.string().optional(),
  provider: z.string().optional(),
  model: z.string().optional(),
  extensions: z.array(z.string()).optional(),
  skills: z.array(z.string()).optional(),
  /** Extra env for the pi subprocess (tests use this for a hermetic HOME). */
  env: z.record(z.string()).optional(),
});

/** Tools only bridge extensions provide — stripped until those bridges are ported (M2). */
const BRIDGE_ONLY_TOOLS = new Set(["contact_supervisor", "managed_subagent", "ask_user"]);

const THINKING_LEVELS = new Set(["off", "minimal", "low", "medium", "high", "xhigh"]);

const agentEditFields = z.object({
  description: z.string().optional(),
  whenToUse: z.string().optional(),
  model: z.string().optional(),
  thinking: z.string().optional(),
  systemPromptMode: z.enum(["replace", "append"]).optional(),
  tools: z.array(z.string()).optional(),
  skills: z.array(z.string()).optional(),
  body: z.string().optional(),
});

const agentEditBody = z.object({
  projectId: z.string().optional(),
  scope: z.enum(["builtin", "global", "project"]),
  name: RESOURCE_NAME,
  edit: agentEditFields,
});

const skillEditBody = z.object({
  projectId: z.string().optional(),
  scope: z.enum(["global", "project"]),
  name: RESOURCE_NAME,
  edit: z.object({
    description: z.string().optional(),
    body: z.string().optional(),
  }),
});

function asThinkingLevel(value: string | undefined): AgentSessionPlan["thinking"] {
  return value && THINKING_LEVELS.has(value) ? (value as AgentSessionPlan["thinking"]) : undefined;
}

/**
 * Session defaults from the server environment. The e2e harness (and any dev
 * setup) uses these to route UI-created sessions to the mock provider without
 * the UI knowing: AGENT_DECK_DEFAULT_PROVIDER, AGENT_DECK_DEFAULT_MODEL,
 * AGENT_DECK_DEFAULT_EXTENSIONS (path.delimiter-separated),
 * AGENT_DECK_PROVIDER_EXTENSIONS (provider-registration extensions only —
 * the ONLY extensions isolated helper launches may load),
 * AGENT_DECK_PI_ENV (JSON object merged into the pi subprocess env).
 */
function envDefaults(): {
  provider?: string;
  model?: string;
  extensions?: string[];
  providerExtensions?: string[];
  env?: Record<string, string>;
} {
  const extensions = process.env.AGENT_DECK_DEFAULT_EXTENSIONS?.split(nodePath.delimiter).filter(
    Boolean,
  );
  const providerExtensions = process.env.AGENT_DECK_PROVIDER_EXTENSIONS?.split(
    nodePath.delimiter,
  ).filter(Boolean);
  let env: Record<string, string> | undefined;
  if (process.env.AGENT_DECK_PI_ENV) {
    try {
      env = JSON.parse(process.env.AGENT_DECK_PI_ENV) as Record<string, string>;
    } catch {
      // Malformed JSON — ignore rather than break session creation.
    }
  }
  return {
    provider: process.env.AGENT_DECK_DEFAULT_PROVIDER,
    model: process.env.AGENT_DECK_DEFAULT_MODEL,
    extensions: extensions?.length ? extensions : undefined,
    providerExtensions: providerExtensions?.length ? providerExtensions : undefined,
    env,
  };
}

export interface AgentDeckServer {
  fastify: FastifyInstance;
  port: number;
  sessions: SessionManager;
  receipts: ReceiptBus;
  close(): Promise<void>;
}

export interface StartServerOptions {
  port?: number;
  host?: string;
  dataDir?: string;
  /** Serve a built web app (apps/web/dist) at /. */
  staticDir?: string;
}

export async function startServer(options: StartServerOptions = {}): Promise<AgentDeckServer> {
  const receipts = new ReceiptBus(process.env.AGENT_DECK_TEST === "1");
  const index = new SessionIndex(options.dataDir);
  const sessions = new SessionManager(
    receipts,
    (meta) => {
      index.upsert(meta);
      // `broadcast` is initialized during startServer, before any meta changes.
      broadcast({ type: "session_meta", session: meta });
    },
    () => envDefaults().providerExtensions,
  );
  const projects = new ProjectIndex(options.dataDir);
  const settings = new SettingsStore(options.dataDir);
  const fastify = Fastify({ logger: false });

  if (options.staticDir) {
    await fastify.register(fastifyStatic, { root: options.staticDir });
  }

  fastify.get("/health", async () => ({ ok: true }));

  // Resource scanning. `home` follows the pi subprocess HOME override (set via
  // AGENT_DECK_PI_ENV in tests) so the scanner and pi see the same catalogs.
  const resourceHome = (): string => {
    const piEnv = envDefaults().env;
    return piEnv?.HOME ?? homedir();
  };
  const rootsFor = (projectId?: string): ResourceRoots => ({
    home: resourceHome(),
    projectPath: projectId ? projects.find((p) => p.id === projectId)?.path : undefined,
  });

  fastify.get("/resources/agents", async (request) => {
    const { projectId } = request.query as { projectId?: string };
    return { agents: scanAgents(rootsFor(projectId)) };
  });

  // Skills carry the app-level disabled flag from settings.
  const enrichSkills = (skills: SkillInfo[]): SkillInfo[] => {
    const disabled = new Set(settings.get().disabledSkills);
    return skills.map((s) => ({ ...s, disabled: disabled.has(s.name) }));
  };

  fastify.get("/resources/skills", async (request) => {
    const { projectId } = request.query as { projectId?: string };
    return { skills: enrichSkills(scanSkills(rootsFor(projectId))) };
  });

  // Delete a global/project skill (its SKILL.md dir) and forget it everywhere.
  fastify.delete("/resources/skills", async (request, reply) => {
    const parsed = z
      .object({
        projectId: z.string().optional(),
        scope: z.enum(["global", "project"]),
        name: RESOURCE_NAME,
      })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { projectId, scope, name } = parsed.data;
    if (scope === "project" && !rootsFor(projectId).projectPath) {
      return reply.status(400).send({ error: "projectId required for project scope" });
    }
    try {
      deleteSkillDir(rootsFor(projectId), scope, name);
      settings.forgetSkill(name);
      for (const project of projects.list()) {
        if (project.assignedSkills?.includes(name)) {
          projects.upsert({
            ...project,
            assignedSkills: project.assignedSkills.filter((s) => s !== name),
          });
        }
      }
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  // Edit-safety contract: builtin agents are NEVER written — edits become a
  // diff vs the pristine builtin at settings.json → subagents.agentOverrides.
  // The UI sends the complete form state, so the computed diff fully replaces
  // any prior override (reverting a field back to base clears it).
  fastify.put("/resources/agents", async (request, reply) => {
    const parsed = agentEditBody.safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { projectId, scope, name, edit } = parsed.data;
    const roots = rootsFor(projectId);
    try {
      if (scope === "builtin") {
        const builtinFile = nodePath.join(BUILTIN_AGENTS_DIR, `${name}.md`);
        if (!existsSync(builtinFile)) {
          return reply.status(404).send({ error: `unknown builtin agent: ${name}` });
        }
        const base = parseAgentFile(builtinFile, readFileSync(builtinFile, "utf8"), "builtin");
        // Merge: fields this editor doesn't manage (disabled, mcpServers, …)
        // survive; managed fields are fully recomputed from the form state.
        const merged = mergeWithUnmanagedOverrideFields(
          readAgentOverrides(roots)[name],
          computeBuiltinOverride(base, edit),
        );
        writeBuiltinAgentOverride(roots, name, merged);
      } else {
        if (scope === "project" && !roots.projectPath) {
          return reply.status(400).send({ error: "projectId required for project scope" });
        }
        writeAgentFile(roots, scope, name, edit);
      }
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
    // settings.json isn't under the resource watcher — notify clients directly.
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  // Toggle an agent's disabled flag: override for builtins, frontmatter for
  // global/project. Library agents are read-only.
  fastify.post("/resources/agents/disabled", async (request, reply) => {
    const parsed = z
      .object({
        projectId: z.string().optional(),
        scope: z.enum(["builtin", "global", "project"]),
        name: RESOURCE_NAME,
        disabled: z.boolean(),
      })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { projectId, scope, name, disabled } = parsed.data;
    const roots = rootsFor(projectId);
    try {
      if (scope === "builtin") {
        if (!existsSync(nodePath.join(BUILTIN_AGENTS_DIR, `${name}.md`))) {
          return reply.status(404).send({ error: `unknown builtin agent: ${name}` });
        }
        const existing = readAgentOverrides(roots)[name] ?? {};
        const next = { ...existing };
        if (disabled) next.disabled = true;
        else delete next.disabled;
        writeBuiltinAgentOverride(roots, name, Object.keys(next).length > 0 ? next : null);
      } else {
        if (scope === "project" && !roots.projectPath) {
          return reply.status(400).send({ error: "projectId required for project scope" });
        }
        setAgentDisabledFile(roots, scope, name, disabled);
      }
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  // Delete a custom (global/project) agent's file. Builtins can't be deleted;
  // "delete" for a builtin means removing its override (reset to pristine).
  fastify.delete("/resources/agents", async (request, reply) => {
    const parsed = z
      .object({
        projectId: z.string().optional(),
        scope: z.enum(["builtin", "global", "project"]),
        name: RESOURCE_NAME,
      })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { projectId, scope, name } = parsed.data;
    const roots = rootsFor(projectId);
    try {
      if (scope === "builtin") {
        if (!existsSync(nodePath.join(BUILTIN_AGENTS_DIR, `${name}.md`))) {
          return reply.status(404).send({ error: `unknown builtin agent: ${name}` });
        }
        // "Reset to pristine" — remove the entire override, including any
        // unmanaged keys (mcpServers, …). This is why the UI only offers
        // reset for a builtin that is currently overridden.
        writeBuiltinAgentOverride(roots, name, null);
      } else {
        if (scope === "project" && !roots.projectPath) {
          return reply.status(400).send({ error: "projectId required for project scope" });
        }
        deleteAgentFile(roots, scope, name);
        // A deleted agent can no longer be a project default.
        for (const project of projects.list()) {
          if (project.defaultAgentName === name) {
            projects.upsert({ ...project, defaultAgentName: undefined });
          }
        }
      }
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  fastify.put("/resources/skills", async (request, reply) => {
    const parsed = skillEditBody.safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { projectId, scope, name, edit } = parsed.data;
    const roots = rootsFor(projectId);
    if (scope === "project" && !roots.projectPath) {
      return reply.status(400).send({ error: "projectId required for project scope" });
    }
    try {
      writeSkillFile(roots, scope, name, edit);
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  // Runtime screens: masked env inspector and the doctor health probe.
  fastify.get("/runtime/env", async (request) => {
    const { projectId } = request.query as { projectId?: string };
    return { entries: scanEnv(rootsFor(projectId)) };
  });

  // Set or add an env var (value provided) in the given scope's .env.
  fastify.put("/runtime/env", async (request, reply) => {
    const parsed = z
      .object({
        projectId: z.string().optional(),
        scope: z.enum(["global", "project"]),
        key: z.string().regex(/^[A-Za-z_][A-Za-z0-9_]*$/, "invalid env key"),
        value: z
          .string()
          .max(100_000)
          .refine((v) => !/[\r\n]/.test(v), "env values cannot contain newlines"),
      })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { projectId, scope, key, value } = parsed.data;
    if (scope === "project" && !rootsFor(projectId).projectPath) {
      return reply.status(400).send({ error: "projectId required for project scope" });
    }
    try {
      writeEnvVar(rootsFor(projectId), scope, key, value);
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  // Delete an env var from the given scope's .env.
  fastify.delete("/runtime/env", async (request, reply) => {
    const parsed = z
      .object({
        projectId: z.string().optional(),
        scope: z.enum(["global", "project"]),
        key: z.string().regex(/^[A-Za-z_][A-Za-z0-9_]*$/, "invalid env key"),
      })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { projectId, scope, key } = parsed.data;
    if (scope === "project" && !rootsFor(projectId).projectPath) {
      return reply.status(400).send({ error: "projectId required for project scope" });
    }
    try {
      writeEnvVar(rootsFor(projectId), scope, key, null);
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  fastify.get("/runtime/doctor", async () => ({ report: await runDoctor(resourceHome()) }));

  fastify.get("/settings", async () => ({ settings: settings.get() }));

  fastify.patch("/settings", async (request, reply) => {
    const parsed = z
      .object({
        defaultSkills: z.array(RESOURCE_NAME).optional(),
        /** Atomic membership ops — preferred over whole-array replacement. */
        setDefaultSkill: z.object({ name: RESOURCE_NAME, enabled: z.boolean() }).optional(),
        setDisabledSkill: z.object({ name: RESOURCE_NAME, disabled: z.boolean() }).optional(),
      })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    if (parsed.data.setDefaultSkill) {
      const { name, enabled } = parsed.data.setDefaultSkill;
      return { settings: settings.setDefaultSkill(name, enabled) };
    }
    if (parsed.data.setDisabledSkill) {
      const { name, disabled } = parsed.data.setDisabledSkill;
      const result = settings.setDisabledSkill(name, disabled);
      broadcast({ type: "resources_changed" }); // dims the row, updates assignment
      return { settings: result };
    }
    return { settings: settings.update(parsed.data) };
  });

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
    if (parsed.data.defaultAgentName !== undefined) {
      next.defaultAgentName = parsed.data.defaultAgentName ?? undefined;
    }
    if (parsed.data.enabled !== undefined) next.enabled = parsed.data.enabled;
    projects.upsert(next);
    return { project: next };
  });

  // Live pi session state (model, thinking level, streaming flags) and the
  // available-model catalog — the composer's picker data.
  fastify.get("/sessions/:id/state", async (request, reply) => {
    const { id } = request.params as { id: string };
    const session = sessions.get(id);
    if (!session) return reply.status(404).send({ error: "unknown session" });
    try {
      return { state: await session.getState() };
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
  });

  fastify.get("/sessions/:id/models", async (request, reply) => {
    const { id } = request.params as { id: string };
    const session = sessions.get(id);
    if (!session) return reply.status(404).send({ error: "unknown session" });
    try {
      return { models: await session.getAvailableModels() };
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
  });

  // Session slash commands (skills/prompts pi actually loaded) — also how
  // tests verify that assigned --skill flags landed inside pi.
  fastify.get("/sessions/:id/commands", async (request, reply) => {
    const { id } = request.params as { id: string };
    const session = sessions.get(id);
    if (!session) return reply.status(404).send({ error: "unknown session" });
    try {
      return { commands: await session.getCommands() };
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
  });

  // Project-relative file list for `@`-file autocomplete, scoped to the
  // session's cwd. Bounded + symlink-safe (see listProjectFiles).
  fastify.get("/sessions/:id/files", async (request, reply) => {
    const { id } = request.params as { id: string };
    const { q } = request.query as { q?: string };
    const session = sessions.get(id);
    if (!session) return reply.status(404).send({ error: "unknown session" });
    return { files: listProjectFiles(session.meta.cwd, q ?? "").slice(0, 50) };
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

  fastify.get("/sessions", async (request) => {
    const { projectId } = request.query as { projectId?: string };
    // Live sessions win over persisted index entries (same id).
    const live = sessions.list();
    const liveIds = new Set(live.map((s) => s.id));
    const all = [...index.list().filter((s) => !liveIds.has(s.id)), ...live].sort((a, b) =>
      a.createdAt.localeCompare(b.createdAt),
    );
    return { sessions: projectId ? all.filter((s) => s.projectId === projectId) : all };
  });

  // Reopen a session: live ones are returned as-is; ended ones are relaunched
  // against their pi session file with the transcript rebuilt from pi's
  // canonical history (never from our own logs).
  fastify.post("/sessions/:id/resume", async (request, reply) => {
    const { id } = request.params as { id: string };
    const live = sessions.get(id);
    if (live?.isRunning) return { session: live.meta };
    const meta = live?.meta ?? index.find((s) => s.id === id);
    if (!meta) return reply.status(404).send({ error: "unknown session" });
    if (!meta.piSessionFile) {
      return reply.status(409).send({ error: "session has no pi session file to resume" });
    }
    const defaults = envDefaults();
    try {
      const session = await sessions.resume(
        meta,
        {
          kind: "parent",
          resumeSessionPath: meta.piSessionFile,
          provider: defaults.provider,
          model: defaults.model,
          extensions: defaults.extensions,
        },
        defaults.env,
      );
      return { session: session.meta };
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
  });

  // Rename: updates pi's session name (when live) and the persisted title.
  fastify.patch("/sessions/:id", async (request, reply) => {
    const parsed = z.object({ title: z.string().trim().min(1).max(200) }).safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const { id } = request.params as { id: string };
    const live = sessions.get(id);
    if (live) {
      await live.rename(parsed.data.title);
      return { session: live.meta };
    }
    const meta = index.find((s) => s.id === id);
    if (!meta) return reply.status(404).send({ error: "unknown session" });
    const next = { ...meta, title: parsed.data.title };
    index.upsert(next);
    broadcast({ type: "session_meta", session: next });
    return { session: next };
  });

  // Delete: stop the live process, drop the index entry, remove the pi
  // session file. Session content is destroyed — this is the explicit delete.
  fastify.delete("/sessions/:id", async (request, reply) => {
    const { id } = request.params as { id: string };
    const meta = sessions.get(id)?.meta ?? index.find((s) => s.id === id);
    if (!meta) return reply.status(404).send({ error: "unknown session" });
    await sessions.destroy(id);
    index.remove(id);
    if (meta.piSessionFile) {
      try {
        rmSync(meta.piSessionFile, { force: true });
      } catch {
        // pi may still hold the file briefly; best-effort.
      }
    }
    broadcast({ type: "session_removed", sessionId: id });
    return { ok: true };
  });

  // Fork/duplicate: copy the source's pi session file and launch an
  // independent resumed session from the copy. The original is untouched.
  fastify.post("/sessions/:id/fork", async (request, reply) => {
    const { id } = request.params as { id: string };
    const live = sessions.get(id);
    const meta = live?.meta ?? index.find((s) => s.id === id);
    if (!meta) return reply.status(404).send({ error: "unknown session" });
    if (!meta.piSessionFile || !existsSync(meta.piSessionFile)) {
      return reply.status(409).send({ error: "session has no history to fork yet" });
    }
    // Copying a session file mid-write (streaming) can yield a torn copy the
    // fork can't resume — refuse while the source is actively responding.
    if (live?.isRunning) {
      try {
        const state = await live.getState();
        if (state.isStreaming) {
          return reply.status(409).send({ error: "cannot fork while the session is responding" });
        }
      } catch {
        // Couldn't read state — proceed; the source file is only appended to.
      }
    }
    const ext = nodePath.extname(meta.piSessionFile);
    const base = nodePath.basename(meta.piSessionFile, ext);
    const dir = nodePath.dirname(meta.piSessionFile);
    // Full UUID + existence check so the fork can never overwrite another file.
    let copyTo = "";
    do {
      copyTo = nodePath.join(dir, `${base}-fork-${randomUUID()}${ext}`);
    } while (existsSync(copyTo));
    try {
      const session = await sessions.fork(meta, meta.piSessionFile, copyTo, envDefaults().env);
      index.upsert(session.meta);
      return reply.status(201).send({ session: session.meta });
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
  });

  fastify.post("/sessions", async (request, reply) => {
    const parsed = createSessionBody.safeParse(request.body);
    if (!parsed.success) {
      return reply.status(400).send({ error: parsed.error.message });
    }
    const body = parsed.data;
    const defaults = envDefaults();
    let cwd = body.cwd ?? process.cwd();
    if (body.projectId) {
      const project = projects.find((p) => p.id === body.projectId);
      if (!project) return reply.status(404).send({ error: "unknown project" });
      cwd = project.path;
    }

    const provider = body.provider ?? defaults.provider;
    const model = body.model ?? defaults.model;
    const extensions = body.extensions ?? defaults.extensions;

    // Default + project skill assignments become explicit --skill paths on
    // parent sessions (pi-rpc-launch-flags.md §1: "Default + current Project
    // skill assignments"). Applied at session creation; a running session
    // keeps its flags until relaunched.
    // CONTRACT GAP: bridge/audit/web extensions and APPEND_SYSTEM.md
    // preservation are still missing here (M2).
    let assignedSkillPaths: string[] | undefined;
    {
      const project = body.projectId ? projects.find((p) => p.id === body.projectId) : undefined;
      const disabledSkills = new Set(settings.get().disabledSkills);
      const names = [...settings.get().defaultSkills, ...(project?.assignedSkills ?? [])].filter(
        (name) => !disabledSkills.has(name), // disabled skills are never injected
      );
      if (names.length > 0) {
        // scanSkills lists global catalogs first and the project catalog
        // last; the Map keeps the LAST entry per name, so a project skill
        // deliberately wins a name collision with a global one.
        const skillsByName = new Map(scanSkills(rootsFor(body.projectId)).map((s) => [s.name, s]));
        const missing = [...new Set(names)].filter((name) => !skillsByName.has(name));
        if (missing.length > 0) {
          fastify.log.warn({ missing }, "assigned skills not found in catalog");
        }
        const paths = [...new Set(names)]
          .map((name) => skillsByName.get(name)?.baseDir)
          .filter((p): p is string => Boolean(p));
        if (paths.length > 0) assignedSkillPaths = paths;
      }
    }

    let plan: LaunchPlan = {
      kind: "parent",
      provider,
      model,
      extensions,
      skills: body.skills ?? assignedSkillPaths,
    };

    if (body.agentName) {
      // Agent-backed session: the picked agent's body becomes the system
      // prompt; frontmatter tools/skills/model apply per the launch contract.
      const roots = rootsFor(body.projectId);
      const agent = scanAgents(roots).find((a) => a.name === body.agentName && !a.shadowed);
      if (!agent) return reply.status(404).send({ error: `unknown agent: ${body.agentName}` });
      if (agent.disabled) {
        return reply.status(409).send({ error: `agent is disabled: ${body.agentName}` });
      }
      const skillsByName = new Map(scanSkills(roots).map((s) => [s.name, s]));
      const disabledSkills = new Set(settings.get().disabledSkills);
      const agentSkillPaths = (agent.skills ?? [])
        .filter((name) => !disabledSkills.has(name)) // disabled skills never inject
        .map((name) => skillsByName.get(name)?.baseDir)
        .filter((p): p is string => Boolean(p));
      const effectiveTools = agent.tools?.filter((tool) => !BRIDGE_ONLY_TOOLS.has(tool));
      plan = {
        kind: "agent",
        systemPrompt: { mode: agent.systemPromptMode, text: agent.body },
        tools: effectiveTools,
        extensions: [...(extensions ?? []), ...(agent.extensions ?? [])],
        skills: agentSkillPaths,
        provider,
        // Agent model, else the inherited default; frontmatter thinking applies
        // either way (suffix when a model is known, --thinking otherwise).
        model: agent.model ?? model,
        thinking: asThinkingLevel(agent.thinking),
      };
    }

    const session = sessions.create({
      cwd,
      projectId: body.projectId,
      agentName: body.agentName,
      env: { ...defaults.env, ...body.env },
      plan,
    });
    index.upsert(session.meta);
    return reply.status(201).send({ session: session.meta });
  });

  // WebSocket: live domain-event push + session commands.
  const wss = new WebSocketServer({ noServer: true });
  const clients = new Set<WebSocket>();

  const send = (socket: WebSocket, message: ServerMessage): void => {
    if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(message));
  };

  const broadcast = (message: ServerMessage): void => {
    for (const client of clients) send(client, message);
  };

  // One coarse watcher: global catalogs at boot, project dirs added as
  // projects register. Any change → resources_changed → clients re-fetch.
  const resourceWatcher = watchResources({ home: resourceHome() }, () =>
    broadcast({ type: "resources_changed" }),
  );
  const watchedProjects = new Set<string>();
  const watchProject = (projectPath: string): void => {
    if (watchedProjects.has(projectPath)) return;
    watchedProjects.add(projectPath);
    resourceWatcher.add(ensureDirs(projectWatchDirs(projectPath)));
  };
  for (const project of projects.list()) watchProject(project.path);

  // Per-socket subscription bookkeeping: re-subscribing to the same session
  // replaces the old subscription (no duplicate events), and every listener —
  // bus subscriber AND session exit listener — is released on socket close.
  const socketCleanups = new Map<WebSocket, Map<string, () => void>>();

  const subscribe = (socket: WebSocket, session: ManagedSession, lastSeq?: number): void => {
    const cleanups = socketCleanups.get(socket) ?? new Map<string, () => void>();
    socketCleanups.set(socket, cleanups);
    cleanups.get(session.meta.id)?.();

    const unsubscribeBus = session.bus.subscribe(({ seq, event }) => {
      send(socket, { type: "event", sessionId: session.meta.id, seq, event });
    });
    const unsubscribeExit = session.onExit((exit) =>
      send(socket, {
        type: "session_exit",
        sessionId: session.meta.id,
        code: exit.code,
        signal: exit.signal,
      }),
    );
    cleanups.set(session.meta.id, () => {
      unsubscribeBus();
      unsubscribeExit();
    });

    if (lastSeq !== undefined) {
      const replay = session.bus.replayFrom(lastSeq);
      if (replay) {
        for (const { seq, event } of replay) {
          send(socket, { type: "event", sessionId: session.meta.id, seq, event });
        }
        return;
      }
    }
    const { seq, state } = session.snapshot();
    send(socket, { type: "snapshot", sessionId: session.meta.id, seq, state });
  };

  wss.on("connection", (socket: WebSocket) => {
    clients.add(socket);
    socket.on("close", () => {
      clients.delete(socket);
      const cleanups = socketCleanups.get(socket);
      socketCleanups.delete(socket);
      if (cleanups) for (const cleanup of cleanups.values()) cleanup();
    });
    socket.on("message", (raw: Buffer) => {
      void (async () => {
        let message;
        try {
          message = clientMessageSchema.parse(JSON.parse(raw.toString("utf8")));
        } catch (error) {
          send(socket, { type: "error", message: `invalid message: ${String(error)}` });
          return;
        }
        if (message.type === "hello") {
          send(socket, { type: "hello_ok", sessions: sessions.list() });
          return;
        }
        const session = sessions.get(message.sessionId);
        if (!session) {
          send(socket, {
            type: "error",
            message: "unknown session",
            sessionId: message.sessionId,
          });
          return;
        }
        try {
          switch (message.type) {
            case "subscribe_session":
              subscribe(socket, session, message.lastSeq);
              break;
            case "prompt":
              await session.prompt(message.message, message.images);
              break;
            case "steer":
              await session.steer(message.message);
              break;
            case "follow_up":
              await session.followUp(message.message);
              break;
            case "abort":
              await session.abort();
              break;
            case "set_model": {
              // Only switch to models pi actually offers.
              const available = await session.getAvailableModels();
              const known = available.some(
                (m) => m.provider === message.provider && m.id === message.modelId,
              );
              if (!known) {
                send(socket, {
                  type: "error",
                  message: `unknown model: ${message.provider}/${message.modelId}`,
                  sessionId: message.sessionId,
                });
                break;
              }
              await session.setModel(message.provider, message.modelId);
              break;
            }
            case "set_thinking":
              await session.setThinkingLevel(message.level);
              break;
            case "ui_response":
              session.respondToUiRequest(message.response);
              break;
          }
        } catch (error) {
          send(socket, {
            type: "error",
            message: String(error),
            sessionId: message.sessionId,
          });
        }
      })();
    });
  });

  // Browsers may open cross-origin WebSockets to localhost services; only
  // accept upgrades from local origins (or non-browser clients, which send
  // no Origin header) so a hostile web page can't drive sessions.
  const isTrustedOrigin = (origin: string | undefined): boolean => {
    if (origin === undefined) return true; // ws library clients, curl, tests
    try {
      const { hostname } = new URL(origin);
      return hostname === "127.0.0.1" || hostname === "localhost" || hostname === "::1";
    } catch {
      return false;
    }
  };

  fastify.server.on("upgrade", (request: IncomingMessage, socket, head) => {
    if (request.url !== "/ws" || !isTrustedOrigin(request.headers.origin)) {
      socket.destroy();
      return;
    }
    wss.handleUpgrade(request, socket, head, (ws) => wss.emit("connection", ws, request));
  });

  await fastify.listen({ port: options.port ?? 0, host: options.host ?? "127.0.0.1" });
  const address = fastify.server.address();
  const port = typeof address === "object" && address !== null ? address.port : 0;

  return {
    fastify,
    port,
    sessions,
    receipts,
    close: async () => {
      await resourceWatcher.close();
      await sessions.stopAll();
      wss.close();
      await fastify.close();
    },
  };
}
