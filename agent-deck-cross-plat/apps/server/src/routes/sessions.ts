import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, rmSync } from "node:fs";
import { readFile } from "node:fs/promises";
import nodePath from "node:path";
import type { ProjectMeta } from "@agent-deck/contracts";
import type { PromptInfo } from "@agent-deck/domain";
import { listProjectFiles, scanPrompts, scanSkills } from "@agent-deck/resources";
import { z } from "zod";
import {
  createSessionWorktree,
  gitCommitAll,
  gitCommitsAhead,
  gitErrorText,
  gitMerge,
  gitWorktreeRemove,
  isGitRepo,
  type GitWorktree,
} from "../git.ts";
import type { LaunchPlan } from "../SessionManager.ts";
import { asThinkingLevel, envDefaults, type ServerContext } from "../context.ts";
import { finalizeExtensions } from "./shared.ts";

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

/**
 * Session routes — list/search, create (incl. worktree isolation and
 * agent-backed launches), resume/rename/delete, merge/fork, and the live pi
 * state screens. Moved verbatim from server.ts.
 */
export function registerSessionRoutes(ctx: ServerContext): void {
  const {
    fastify,
    sessions,
    index,
    projects,
    settings,
    bridgeTokens,
    worktreesRoot,
    broadcast,
    rootsFor,
    resolveNamedAgent,
    enabledExtensionPaths,
    dropDiffCache,
  } = ctx;

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

  // Live token / cost / context-usage totals for a session (native session
  // context-usage indicator). Returns pi's get_session_stats verbatim; the
  // context-usage percent is null until the first LLM response.
  fastify.get("/sessions/:id/stats", async (request, reply) => {
    const { id } = request.params as { id: string };
    const session = sessions.get(id);
    if (!session) return reply.status(404).send({ error: "unknown session" });
    try {
      return { stats: await session.getSessionStats() };
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
  });

  fastify.get("/sessions/:id/models", async (request, reply) => {
    const { id } = request.params as { id: string };
    const session = sessions.get(id);
    if (!session) return reply.status(404).send({ error: "unknown session" });
    try {
      const models = await session.getAvailableModels();
      // Mark models the user hid from the picker (app-level, native "Disabled").
      const disabled = new Set(settings.get().disabledModels);
      return {
        models: models.map((m) => ({
          ...m,
          disabled: disabled.has(`${m.provider}:${m.id}`),
        })),
      };
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

  // Content search across sessions (native Sessions search 18.1 "by title or
  // content"): scans each session's pi session file — the canonical transcript,
  // uniform for live and ended sessions — for the query. Title matching stays on
  // the client; this adds the content half, returning the matching session ids.
  fastify.get("/sessions/search", async (request) => {
    const q = String((request.query as { q?: string }).q ?? "")
      .trim()
      .toLowerCase();
    if (!q) return { ids: [] as string[] };
    const withFiles = index.list().filter((meta) => meta.piSessionFile);
    const ids: string[] = [];
    // Scan in bounded batches so a large session history can't exhaust file
    // descriptors (EMFILE). The message text is embedded as JSON string values,
    // so a lowercase substring match over the whole file finds it (it may
    // occasionally match structural JSON — an acceptable false-positive for a
    // free-text search).
    const BATCH = 24;
    for (let i = 0; i < withFiles.length; i += BATCH) {
      const hits = await Promise.all(
        withFiles.slice(i, i + BATCH).map(async (meta) => {
          try {
            const content = await readFile(meta.piSessionFile!, "utf8");
            return content.toLowerCase().includes(q) ? meta.id : null;
          } catch {
            return null; // unreadable / since-deleted file — skip
          }
        }),
      );
      for (const id of hits) if (id) ids.push(id);
    }
    return { ids };
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
    // A session with no pi session file never ran a turn (a draft, or an old
    // entry from before session files existed). It has nothing to restore, but
    // opening it should still work — sessions.resume launches a FRESH parent pi
    // (resumeSessionPath is undefined) with the session's project/agent context
    // and an empty transcript, rather than erroring.
    const defaults = envDefaults();
    try {
      const session = await sessions.resume(
        meta,
        {
          kind: "parent",
          resumeSessionPath: meta.piSessionFile,
          provider: defaults.provider,
          model: defaults.model,
          // Include provider-registration extensions so a session with no stored
          // launch plan (old/draft) still relaunches with its provider available.
          extensions: [...(defaults.extensions ?? []), ...(defaults.providerExtensions ?? [])],
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
    const next = { ...meta, title: parsed.data.title, updatedAt: new Date().toISOString() };
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
    bridgeTokens.delete(id);
    if (meta.piSessionFile) {
      try {
        rmSync(meta.piSessionFile, { force: true });
      } catch {
        // pi may still hold the file briefly; best-effort.
      }
    }
    // Remove the session's isolated worktree (native: session-delete removes the
    // worktree). The BRANCH is deliberately kept so committed-but-unmerged work is
    // never lost (gitWorktreeRemove doesn't delete it). destroy() above awaited the
    // pi exit, so the checkout is no longer in use (matters on Windows).
    if (meta.worktreePath && meta.projectId) {
      const project = projects.find((p) => p.id === meta.projectId);
      if (project) await gitWorktreeRemove(project.path, meta.worktreePath).catch(() => {});
    }
    broadcast({ type: "session_removed", sessionId: id });
    return { ok: true };
  });

  // Merge an isolated session's worktree back into its source branch (native
  // Merge toolbar action): auto-commit the worktree's changes, then a --no-ff
  // merge into the source branch. The worktree + branch are kept (native default
  // keepWorktreeAfterMerge) so the user can keep iterating and merge again.
  fastify.post("/sessions/:id/merge", async (request, reply) => {
    const { id } = request.params as { id: string };
    const meta = sessions.get(id)?.meta ?? index.find((s) => s.id === id);
    if (!meta) return reply.status(404).send({ error: "unknown session" });
    const { worktreePath, worktreeBranch, worktreeSourceBranch, projectId } = meta;
    if (!worktreePath || !worktreeBranch || !worktreeSourceBranch) {
      return reply
        .status(400)
        .send({ error: "This session isn't running in an isolated worktree." });
    }
    const project = projectId ? projects.find((p) => p.id === projectId) : undefined;
    if (!project) return reply.status(404).send({ error: "unknown project" });

    // 1. Commit any uncommitted worktree work (native auto-commits first);
    //    nothing-to-commit is fine — earlier turns may already have committed.
    try {
      await gitCommitAll(worktreePath, `Agent Deck: ${meta.title ?? "session"} changes`);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (message !== "nothing_to_commit") {
        return reply
          .status(400)
          .send({ error: `Couldn't commit the worktree changes: ${gitErrorText(error)}` });
      }
    }
    // 2. Nothing ahead of the source branch → nothing to merge.
    const ahead = await gitCommitsAhead(project.path, worktreeBranch, worktreeSourceBranch).catch(
      () => 0,
    );
    if (ahead === 0) {
      return reply.status(400).send({ error: "Nothing to merge — the session made no commits." });
    }
    // 3. Merge into the source branch. A dirty parent tree / conflict surfaces
    //    the git stderr; the committed work stays safe on the session branch.
    try {
      await gitMerge(project.path, worktreeBranch, worktreeSourceBranch);
    } catch (error) {
      return reply.status(409).send({ error: `Merge failed: ${gitErrorText(error)}` });
    }
    // The merge auto-committed + merged all worktree work, so the session's
    // working-tree-vs-HEAD diff is now empty. Drop the cached changed-file set so
    // a resubscribe before the next turn boundary recomputes it (empty) instead
    // of replaying the pre-merge set and re-offering a merge that now 400s.
    dropDiffCache(id);
    return { ok: true, branch: worktreeBranch, sourceBranch: worktreeSourceBranch, commits: ahead };
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
    let cwd = body.cwd ?? defaults.cwd ?? process.cwd();
    let project: ProjectMeta | undefined;
    if (body.projectId) {
      project = projects.find((p) => p.id === body.projectId);
      if (!project) return reply.status(404).send({ error: "unknown project" });
      cwd = project.path;
    }

    // Worktree isolation (native piAgentSessionsUseWorktree): when on and the
    // project is a git repo, run this session in its own worktree on a fresh
    // `agent-deck/session-<id>` branch so its work never touches the main
    // checkout — the Merge action brings it back. Best-effort: any failure (not
    // a repo, detached HEAD, git error) falls back to the project root.
    let worktree: GitWorktree | null = null;
    if (settings.get().worktreeIsolation && project && (await isGitRepo(project.path))) {
      const suffix = randomUUID().slice(0, 8);
      const target = nodePath.join(worktreesRoot, suffix);
      try {
        mkdirSync(worktreesRoot, { recursive: true }); // git worktree add won't create missing parents
        worktree = await createSessionWorktree(
          project.path,
          target,
          `agent-deck/session-${suffix}`,
        );
        cwd = target;
      } catch {
        // NEVER let a worktree failure (detached HEAD, not a branch, git error)
        // fail the request — fall back to the project root (worktree stays null).
      }
    }

    // Resolve provider + model. Precedence: explicit request → the user's default
    // model (native onboarding preference) → env default. The default model is
    // stored provider-qualified ("provider:id") so it launches under the RIGHT
    // provider — a bare id can't disambiguate two providers exposing the same id.
    let provider = body.provider ?? defaults.provider;
    let model = body.model;
    if (model === undefined) {
      const defaultModel = settings.get().defaultModel; // "provider:id" | "id" | null
      if (defaultModel) {
        const sep = defaultModel.indexOf(":");
        if (sep > 0) {
          if (body.provider === undefined) provider = defaultModel.slice(0, sep);
          model = defaultModel.slice(sep + 1);
        } else {
          model = defaultModel; // unqualified — launch under the resolved provider
        }
      }
    }
    model = model ?? defaults.model;
    // Base extensions (request or env defaults) + the user's enabled ones,
    // deduped and re-validated as real files at launch time.
    const baseExtensions = body.extensions ?? defaults.extensions ?? [];
    const finalizedBase = finalizeExtensions([
      ...baseExtensions,
      ...enabledExtensionPaths(body.projectId),
    ]);
    const extensions = finalizedBase.length > 0 ? finalizedBase : undefined;

    // Default + project skill assignments become explicit --skill paths on
    // parent sessions (pi-rpc-launch-flags.md §1: "Default + current Project
    // skill assignments"). Applied at session creation; a running session
    // keeps its flags until relaunched.
    // CONTRACT GAP: bridge/audit/web extensions and APPEND_SYSTEM.md
    // preservation are still missing here (M2).
    let assignedSkillPaths: string[] | undefined;
    {
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

    // Prompt templates (native: defaultPromptTemplateNames ∪ the project's
    // assignedPromptTemplateNames): the user's "All Projects" defaults PLUS this
    // project's assigned prompts become `--prompt-template <path>` flags so pi
    // exposes them as /<name> slash commands. On a name collision we resolve to
    // the GLOBAL entry (first-wins) — matching pi's own prompt-template loader,
    // which loads global before project and keeps the first (unlike skills, where
    // a project skill deliberately shadows the global one). scanPrompts sorts a
    // same-named collision global-before-project, so keeping the first occurrence
    // yields the global file.
    let defaultPromptTemplatePaths: string[] | undefined;
    {
      const names = [...settings.get().defaultPromptTemplates, ...(project?.assignedPrompts ?? [])];
      if (names.length > 0) {
        const promptsByName = new Map<string, PromptInfo>();
        for (const prompt of scanPrompts(rootsFor(body.projectId))) {
          if (!promptsByName.has(prompt.name)) promptsByName.set(prompt.name, prompt);
        }
        const paths = [...new Set(names)]
          .map((name) => promptsByName.get(name)?.filePath)
          .filter((p): p is string => Boolean(p));
        if (paths.length > 0) defaultPromptTemplatePaths = paths;
      }
    }

    let plan: LaunchPlan = {
      kind: "parent",
      provider,
      model,
      // The user's default thinking level (native onboarding preference) seeds a
      // plain parent session; launchPlan encodes it as the `--model model:level`
      // suffix when a model is known, else `--thinking`.
      thinking: settings.get().defaultThinking ?? undefined,
      extensions,
      skills: body.skills ?? assignedSkillPaths,
      promptTemplates: defaultPromptTemplatePaths,
    };

    if (body.agentName) {
      // Agent-backed session: the picked agent's body becomes the system
      // prompt; frontmatter tools/skills/model apply per the launch contract.
      // Resolved via the same helper the subagent delegation uses, so both paths
      // stay in lock-step.
      const resolved = resolveNamedAgent(body.agentName, body.projectId);
      if (resolved.status === "not_found") {
        return reply.status(404).send({ error: `unknown agent: ${body.agentName}` });
      }
      if (resolved.status === "disabled") {
        return reply.status(409).send({ error: `agent is disabled: ${body.agentName}` });
      }
      const { agent } = resolved;
      plan = {
        kind: "agent",
        systemPrompt: { mode: agent.systemPromptMode, text: agent.body },
        tools: agent.tools,
        extensions: finalizeExtensions([...(extensions ?? []), ...agent.extensions]),
        skills: agent.skillDirs,
        provider,
        // Agent model/thinking, else the inherited defaults (frontmatter wins;
        // an agent that specifies neither falls back to the user's default model
        // AND default thinking, the same precedence a plain parent gets).
        model: agent.model ?? model,
        thinking: asThinkingLevel(agent.thinking) ?? settings.get().defaultThinking ?? undefined,
      };
    }

    const session = sessions.create({
      cwd,
      projectId: body.projectId,
      agentName: body.agentName,
      env: { ...defaults.env, ...body.env },
      plan,
      // Passed INTO create so the worktree fields land on the initial meta (and
      // its first persist) atomically with cwd — no window where cwd points at a
      // worktree that meta doesn't record.
      ...(worktree ? { worktree } : {}),
    });
    index.upsert(session.meta);
    return reply.status(201).send({ session: session.meta });
  });
}
