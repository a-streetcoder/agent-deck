import {
  deleteMcpServer,
  isValidHttpMcpUrl,
  McpConfigError,
  writeMcpServer,
} from "@agent-deck/resources";
import { z } from "zod";
import type { ServerContext } from "../context.ts";

/**
 * MCP server routes — live connection state, add/remove/refresh, and the OAuth
 * sign-in flow for authed http servers. Moved verbatim from server.ts.
 */
export function registerMcpRoutes(ctx: ServerContext): void {
  const { fastify, mcp, mcpOAuth, broadcast, rootsFor } = ctx;

  // MCP servers: list live connection state, add/remove/refresh. Adds/removes
  // are written to the app-owned global mcp.json and reflected on the bridge.
  // Add either a stdio server (command [+ args/env]) or an http server (url).
  const mcpAddBody = z.union([
    z.object({
      name: z.string().min(1),
      command: z.string().min(1),
      args: z.array(z.string()).optional(),
      env: z.record(z.string()).optional(),
    }),
    z.object({
      name: z.string().min(1),
      url: z.string().refine(isValidHttpMcpUrl, "url must be a valid http(s) URL"),
    }),
  ]);

  fastify.get("/mcp", async () => {
    // Augment each server with its OAuth state so the UI can show a Sign-in
    // affordance for authed http servers (stdio/anonymous servers stay "none").
    return {
      servers: mcp.status().map((server) => ({
        ...server,
        auth: server.transport === "http" ? mcpOAuth.state(server.id) : { status: "none" },
      })),
    };
  });

  // Begin OAuth for an authed http server: returns the authorization URL to open.
  // The browser redirect's code is submitted to /mcp/:id/login/callback.
  fastify.post("/mcp/:id/login", async (request, reply) => {
    const { id } = request.params as { id: string };
    const serverUrl = mcp.httpUrlFor(id);
    if (!serverUrl) return reply.code(404).send({ error: "unknown http MCP server" });
    const state = await mcpOAuth.beginAuth(id, serverUrl);
    if (state.status === "error") return reply.code(502).send({ error: state.error });
    return { auth: state };
  });

  // Complete OAuth with the code (and state, verified for CSRF) from the redirect,
  // then reconnect the server so its now-authorized tools register.
  const mcpCallbackBody = z.object({ code: z.string().min(1), state: z.string().optional() });
  fastify.post("/mcp/:id/login/callback", async (request, reply) => {
    const { id } = request.params as { id: string };
    const serverUrl = mcp.httpUrlFor(id);
    if (!serverUrl) return reply.code(404).send({ error: "unknown http MCP server" });
    const parsed = mcpCallbackBody.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.message });
    if (!mcpOAuth.verifyState(id, parsed.data.state)) {
      return reply.code(400).send({ error: "state mismatch (possible CSRF) — restart sign-in" });
    }
    const state = await mcpOAuth.submitCode(id, serverUrl, parsed.data.code);
    if (state.status !== "authorized")
      return reply.code(502).send({ error: state.error, auth: state });
    const server = await mcp.refresh(id);
    broadcast({ type: "resources_changed" });
    return { auth: state, server };
  });

  // Forget a server's OAuth tokens (logout), then reconnect so it drops to
  // unauthenticated + un-registers its tools.
  fastify.post("/mcp/:id/logout", async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!mcp.has(id)) return reply.code(404).send({ error: "unknown MCP server" });
    mcpOAuth.clear(id);
    await mcp.refresh(id);
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  fastify.post("/mcp", async (request, reply) => {
    const parsed = mcpAddBody.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.message });
    const data = parsed.data;
    const input =
      "url" in data ? { url: data.url } : { command: data.command, args: data.args, env: data.env };
    try {
      writeMcpServer(rootsFor(), "global", data.name, input);
    } catch (error) {
      const message = error instanceof McpConfigError ? error.message : String(error);
      return reply.code(400).send({ error: message });
    }
    const status = await mcp.connect({ id: data.name, ...input });
    broadcast({ type: "resources_changed" });
    return reply.code(201).send({ server: status });
  });

  fastify.delete("/mcp/:id", async (request, reply) => {
    const { id } = request.params as { id: string };
    const removed = await mcp.remove(id);
    // Also remove it from the config (it may be config-only if never connected,
    // or manager-only if env-sourced). Succeed when EITHER had it.
    let deletedConfig = false;
    try {
      deletedConfig = deleteMcpServer(rootsFor(), "global", id);
    } catch {
      // A malformed mcp.json is not the delete's problem — the live server is gone.
    }
    if (!removed && !deletedConfig) return reply.code(404).send({ error: "unknown MCP server" });
    broadcast({ type: "resources_changed" });
    return { ok: true };
  });

  fastify.post("/mcp/:id/refresh", async (request, reply) => {
    const status = await mcp.refresh((request.params as { id: string }).id);
    if (!status) return reply.code(404).send({ error: "unknown MCP server" });
    broadcast({ type: "resources_changed" });
    return { server: status };
  });
}
