import { existsSync, lstatSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import nodePath from "node:path";
import { runDoctor } from "@agent-deck/pi-host";
import {
  isKnownProvider,
  listProviders,
  logoutProvider,
  scanEnv,
  writeEnvVar,
} from "@agent-deck/resources";
import {
  isKeybindingCommand,
  isValidChord,
  MAX_KEYBINDINGS_COUNT,
  type KeybindingBinding,
} from "@agent-deck/contracts";
import { z } from "zod";
import type { AppSettings } from "../persistence.ts";
import type { ServerContext } from "../context.ts";
import {
  INSTRUCTIONS_MAX,
  RESOURCE_NAME,
  instructionsBody,
  resolveInstructionsFile,
} from "./shared.ts";

/**
 * App settings + runtime screens — /settings, the masked env inspector, the
 * doctor probe, provider auth/login, model curation, and the global
 * instructions editor. Moved verbatim from server.ts.
 */
export function registerSettingsRoutes(ctx: ServerContext): void {
  const { fastify, settings, providerLogin, broadcast, resourceHome, rootsFor } = ctx;

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

  // Provider auth (native provider-login surface): the OAuth-capable model
  // providers pi knows about, plus each one's sign-in status read from the
  // global ~/.pi/agent/auth.json. Interactive OAuth sign-in is a follow-up; this
  // covers the read side + logout (disconnect a stored credential).
  fastify.get("/runtime/providers", async () => ({ providers: listProviders(rootsFor()) }));

  // Disconnect a stored provider credential (native logout). Only a known
  // provider id is accepted, so arbitrary keys can't be poked into auth.json.
  fastify.post("/runtime/providers/:id/logout", async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isKnownProvider(rootsFor(), id)) {
      return reply.status(404).send({ error: `unknown provider: ${id}` });
    }
    try {
      logoutProvider(rootsFor(), id);
    } catch (error) {
      return reply.status(500).send({ error: String(error) });
    }
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  // Interactive OAuth login (native PiProviderLoginService). start → a pollable
  // session that relays pi's AuthStorage.login callbacks (auth-url / device-code
  // / prompt / select / progress) to the client and threads responses back.
  fastify.post("/runtime/providers/:id/login", async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isKnownProvider(rootsFor(), id)) {
      return reply.status(404).send({ error: `unknown provider: ${id}` });
    }
    const loginId = providerLogin.start(rootsFor(), id);
    return reply.status(201).send({ loginId });
  });

  fastify.get("/runtime/providers/login/:loginId", async (request, reply) => {
    const { loginId } = request.params as { loginId: string };
    const since = Number((request.query as { since?: string }).since ?? 0);
    const result = providerLogin.poll(loginId, Number.isFinite(since) ? since : 0);
    if (!result) return reply.status(404).send({ error: "unknown login session" });
    // A finished login changes auth.json — nudge the Providers list to refresh.
    if (result.status === "done") broadcast({ type: "resources_changed" });
    return result;
  });

  fastify.post("/runtime/providers/login/:loginId/respond", async (request, reply) => {
    const { loginId } = request.params as { loginId: string };
    const parsed = z.object({ value: z.string().optional() }).safeParse(request.body ?? {});
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const ok = providerLogin.respond(loginId, parsed.data.value);
    return { ok };
  });

  fastify.post("/runtime/providers/login/:loginId/cancel", async (request) => {
    const { loginId } = request.params as { loginId: string };
    providerLogin.cancel(loginId);
    return { ok: true };
  });

  fastify.get("/settings", async () => ({ settings: settings.get() }));

  fastify.patch("/settings", async (request, reply) => {
    const parsed = z
      .object({
        defaultSkills: z.array(RESOURCE_NAME).optional(),
        /** Atomic membership ops — preferred over whole-array replacement. */
        setDefaultSkill: z.object({ name: RESOURCE_NAME, enabled: z.boolean() }).optional(),
        setDisabledSkill: z.object({ name: RESOURCE_NAME, disabled: z.boolean() }).optional(),
        setDefaultPromptTemplate: z
          .object({ name: RESOURCE_NAME, enabled: z.boolean() })
          .optional(),
        // Onboarding preferences (native OnboardingPreferencesView). null clears
        // defaultModel/defaultThinking back to "inherit the runtime default".
        autoTitle: z.boolean().optional(),
        worktreeIsolation: z.boolean().optional(),
        gitAutomation: z.boolean().optional(),
        defaultModel: z.string().min(1).nullable().optional(),
        defaultThinking: z
          .enum(["off", "minimal", "low", "medium", "high", "xhigh"])
          .nullable()
          .optional(),
        extensionLoadingMode: z.enum(["useMyExtensions", "agentDeckManaged"]).optional(),
        // The remembered open-in-editor choice (Slice 11). An id only — the
        // server maps it to its own detected editor list; never a command.
        preferredEditor: z.string().min(1).max(64).nullable().optional(),
        // User keybinding overrides (Slice 14): a whole-list replacement. Every
        // entry must name a known command and a chord with a real modifier —
        // the same validation the store applies on load, enforced here so a bad
        // rebind is a 400, not a silently-dropped row.
        keybindings: z
          .array(z.object({ command: z.string(), key: z.string() }))
          .max(MAX_KEYBINDINGS_COUNT)
          .refine(
            (list) => list.every((b) => isKeybindingCommand(b.command) && isValidChord(b.key)),
            "invalid keybinding (unknown command or malformed chord)",
          )
          .optional(),
      })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    if (parsed.data.setDefaultSkill) {
      const { name, enabled } = parsed.data.setDefaultSkill;
      return { settings: settings.setDefaultSkill(name, enabled) };
    }
    if (parsed.data.setDefaultPromptTemplate) {
      const { name, enabled } = parsed.data.setDefaultPromptTemplate;
      return { settings: settings.setDefaultPromptTemplate(name, enabled) };
    }
    if (parsed.data.setDisabledSkill) {
      const { name, disabled } = parsed.data.setDisabledSkill;
      const result = settings.setDisabledSkill(name, disabled);
      broadcast({ type: "resources_changed" }); // dims the row, updates assignment
      return { settings: result };
    }
    // Build a patch of ONLY the provided AppSettings fields — never spread
    // parsed.data directly (its undefined atomic-op keys would clobber existing
    // arrays like defaultSkills through the object spread in settings.update).
    const d = parsed.data;
    const patch: Partial<AppSettings> = {};
    if (d.defaultSkills !== undefined) patch.defaultSkills = d.defaultSkills;
    if (d.autoTitle !== undefined) patch.autoTitle = d.autoTitle;
    if (d.worktreeIsolation !== undefined) patch.worktreeIsolation = d.worktreeIsolation;
    if (d.gitAutomation !== undefined) patch.gitAutomation = d.gitAutomation;
    if (d.defaultModel !== undefined) patch.defaultModel = d.defaultModel;
    if (d.defaultThinking !== undefined) patch.defaultThinking = d.defaultThinking;
    if (d.extensionLoadingMode !== undefined) patch.extensionLoadingMode = d.extensionLoadingMode;
    if (d.preferredEditor !== undefined) patch.preferredEditor = d.preferredEditor;
    // Refine above guarantees every command/chord is valid, so the plain
    // {command,key} shape is safe to store as KeybindingBinding[].
    if (d.keybindings !== undefined) patch.keybindings = d.keybindings as KeybindingBinding[];
    return { settings: settings.update(patch) };
  });

  // Hide/show a model in the picker (app-level curation, the native Enabled/Disabled toggle).
  fastify.post("/runtime/models/disabled", async (request, reply) => {
    const parsed = z
      .object({ provider: z.string().min(1), id: z.string().min(1), disabled: z.boolean() })
      .safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    settings.setModelDisabled(`${parsed.data.provider}:${parsed.data.id}`, parsed.data.disabled);
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  // Global instructions: ~/.pi/agent/AGENTS.md, which pi loads as global context
  // for every session (agent-deck-system-prompt-logic.md §context files).
  // Editable with no project selected — the project-scoped file is separate.
  const globalAgentsPath = (): string =>
    resolveInstructionsFile(nodePath.join(resourceHome(), ".pi", "agent"));

  fastify.get("/runtime/instructions", async (_request, reply) => {
    const filePath = globalAgentsPath();
    let content = "";
    if (existsSync(filePath)) {
      if (statSync(filePath).size > INSTRUCTIONS_MAX) {
        return reply.status(413).send({ error: "the instructions file is too large to edit here" });
      }
      content = readFileSync(filePath, "utf8");
    }
    return { content, path: filePath };
  });

  fastify.put("/runtime/instructions", async (request, reply) => {
    const parsed = instructionsBody.safeParse(request.body);
    if (!parsed.success) return reply.status(400).send({ error: parsed.error.message });
    const filePath = globalAgentsPath();
    // Never write THROUGH a symlink (same guard as the project file).
    if (existsSync(filePath) && lstatSync(filePath).isSymbolicLink()) {
      return reply
        .status(400)
        .send({ error: "the instructions file is a symlink; refusing to write" });
    }
    mkdirSync(nodePath.dirname(filePath), { recursive: true });
    writeFileSync(filePath, parsed.data.content, "utf8");
    return { ok: true, path: filePath };
  });
}
