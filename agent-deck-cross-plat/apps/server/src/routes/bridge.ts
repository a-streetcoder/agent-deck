import { randomUUID } from "node:crypto";
import { buildRecalledMemories, type MemoryStore } from "@agent-deck/memory";
import { z } from "zod";
import type { SupervisorMethod } from "../supervisor.ts";
import type { ServerContext } from "../context.ts";

/** A tool call arriving from a session's generated bridge extension. */
const bridgeCallBody = z.object({
  sessionId: z.string(),
  token: z.string(),
  tool: z.string(),
  toolCallId: z.string(),
  params: z.record(z.unknown()).default({}),
});

/** How long a blocking supervisor request waits for an answer before giving up. */
const SUPERVISOR_TIMEOUT_MS = 110_000;

export interface BridgeRouteHandles {
  /**
   * Release every blocking supervisor request still pending for a child whose
   * bridge is being disposed — invoked by the child-bridge dispose closure in
   * server.ts when a subagent ends.
   */
  cancelChildSupervisorRequests(childSessionId: string): void;
}

/**
 * The app side of the tool bridge and the child-subagent supervisor channel:
 * POST /bridge dispatch plus the blocking supervisor request/answer plumbing.
 * Moved verbatim from server.ts.
 */
export function registerBridgeRoutes(ctx: ServerContext): BridgeRouteHandles {
  const {
    fastify,
    sessions,
    bridge,
    bridgeTokens,
    supervisor,
    childSupervisors,
    pendingSupervisor,
    memoryEnabled,
    memoryBaseDir,
    recallMemories,
  } = ctx;

  // Handle a child subagent's contact_supervisor call. progress_update records +
  // streams into the parent's Subagent card and returns immediately;
  // need_decision / interview_request open a BLOCKING question card in the parent
  // and suspend the child until answerSupervisor() settles it — the answer becomes
  // the child's tool result. A pending wait is released either by an answer, a
  // timeout, or the child's bridge being disposed (child death). Returns the
  // bridge-shaped result the child receives.
  async function handleContactSupervisor(
    childSessionId: string,
    params: Record<string, unknown>,
  ): Promise<{ content: string; isError?: boolean }> {
    const route = childSupervisors.get(childSessionId);
    if (!route) {
      return { content: "No supervisor channel is available for this subagent.", isError: true };
    }
    const rawMethod = typeof params.method === "string" ? params.method : "";
    const validMethods: SupervisorMethod[] = [
      "progress_update",
      "need_decision",
      "interview_request",
    ];
    if (!validMethods.includes(rawMethod as SupervisorMethod)) {
      return {
        content: `contact_supervisor: unknown method '${rawMethod || "(missing)"}'.`,
        isError: true,
      };
    }
    const method = rawMethod as SupervisorMethod;
    const message = typeof params.message === "string" ? params.message.trim() : "";
    if (!message) {
      return { content: "contact_supervisor: 'message' is required.", isError: true };
    }
    const title =
      typeof params.title === "string" && params.title.trim() ? params.title.trim() : undefined;
    const parent = sessions.get(route.parentSessionId);

    if (method === "progress_update") {
      supervisor.record({
        parentSessionId: route.parentSessionId,
        cellId: route.cellId,
        method,
        title,
        message,
      });
      parent?.appendSubagentProgress(route.cellId, title ? `${title}: ${message}` : message);
      return { content: "Progress recorded." };
    }

    // Blocking: open a supervisor-question card and suspend until answered.
    const requestId = randomUUID();
    const options =
      Array.isArray(params.options) && params.options.every((o) => typeof o === "string")
        ? (params.options as string[])
        : undefined;
    supervisor.record({
      id: requestId,
      parentSessionId: route.parentSessionId,
      cellId: route.cellId,
      method,
      title,
      message,
    });
    parent?.openSupervisorQuestion({
      requestId,
      subagentCellId: route.cellId,
      method,
      title: title ?? (method === "need_decision" ? "Decision needed" : "Question"),
      message,
      options,
    });
    return await new Promise<{ content: string; isError?: boolean }>((resolve) => {
      let settled = false;
      const settle = (result: { content: string; isError?: boolean }): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        pendingSupervisor.delete(requestId);
        resolve(result);
      };
      const timer = setTimeout(() => {
        markSupervisorCancelled(requestId, route.parentSessionId, "Timed out with no answer.");
        settle({ content: "Supervisor request timed out with no answer.", isError: true });
      }, SUPERVISOR_TIMEOUT_MS);
      timer.unref();
      pendingSupervisor.set(requestId, {
        parentSessionId: route.parentSessionId,
        childSessionId,
        settle,
      });
    });
  }

  /** Mark a supervisor request cancelled in the log AND close its parent card,
   * so a resolved-without-answer request never leaves stale interactive UI. */
  function markSupervisorCancelled(
    requestId: string,
    parentSessionId: string,
    reason: string,
  ): void {
    supervisor.markCancelled(requestId, reason);
    sessions.get(parentSessionId)?.closeSupervisorQuestion(requestId, reason);
  }

  /**
   * Release every blocking supervisor request still pending for a child whose
   * bridge is being disposed (the child ended/timed out): mark each cancelled +
   * close its card, then settle its (now-dead) tool call so it doesn't linger to
   * the timeout.
   */
  function cancelChildSupervisorRequests(childSessionId: string): void {
    for (const [id, entry] of pendingSupervisor) {
      if (entry.childSessionId === childSessionId) {
        markSupervisorCancelled(id, entry.parentSessionId, "The subagent ended.");
        entry.settle({
          content: "Supervisor request cancelled (the subagent ended).",
          isError: true,
        });
        pendingSupervisor.delete(id);
      }
    }
  }

  /**
   * Deliver an answer to a pending blocking supervisor request: resolve the
   * child's suspended tool call with `response`, mark the record answered, and
   * flip the parent card to answered. Returns false if no such pending request.
   */
  function answerSupervisor(requestId: string, response: string): boolean {
    const pending = pendingSupervisor.get(requestId);
    if (!pending) return false;
    supervisor.markAnswered(requestId, response);
    sessions.get(pending.parentSessionId)?.answerSupervisorQuestion(requestId, response);
    pending.settle({ content: response });
    return true;
  }

  // Memory recall for the before_agent_start hook: rank the session project's
  // memories for the user's message (recallMemories — lexical+fuzzy, or semantic
  // when opted in) and return the top ones' full bodies as an injectable block
  // (empty → the hook injects nothing). The launch index carries only titles;
  // this surfaces the relevant bodies per turn.
  const RECALL_LIMIT = 4;
  async function handleRecall(
    sessionId: string,
    params: Record<string, unknown>,
  ): Promise<{ content: string }> {
    if (!memoryEnabled) return { content: "" };
    const query = typeof params.query === "string" ? params.query : "";
    const cwd = sessions.get(sessionId)?.meta.cwd;
    if (!cwd || !query.trim()) return { content: "" };
    const store: MemoryStore = { baseDir: memoryBaseDir, projectPath: cwd };
    const hits = await recallMemories(store, query, RECALL_LIMIT);
    return { content: buildRecalledMemories(hits.map((h) => h.record)) };
  }

  // The app side of the bridge: a session's generated extension POSTs each
  // app-managed tool call here, and the registry dispatches it to the handler.
  // Loopback-only (the pi subprocess is local); the response maps to the pi
  // tool result, including the error flag.
  fastify.post("/bridge", async (request, reply) => {
    const parsed = bridgeCallBody.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.message });
    }
    const expected = bridgeTokens.get(parsed.data.sessionId);
    if (!expected || expected !== parsed.data.token) {
      return reply.code(403).send({ error: "invalid bridge token" });
    }
    // A child subagent's contact_supervisor call routes to the supervisor channel
    // (recorded + streamed into the parent's card), NOT the parent bridge registry.
    // A blocking method suspends here until answered (or the child's bridge is
    // disposed on child death, which releases the wait).
    if (parsed.data.tool === "contact_supervisor") {
      return await handleContactSupervisor(parsed.data.sessionId, parsed.data.params);
    }
    // The before_agent_start recall hook asks for the memories most relevant to
    // the user's message (not a model-callable tool — an internal hook channel).
    if (parsed.data.tool === "__recall__") {
      return await handleRecall(parsed.data.sessionId, parsed.data.params);
    }
    return await bridge.dispatch(parsed.data);
  });

  // Answer a pending blocking supervisor request (need_decision / interview_request)
  // raised by a child subagent. The "human out-of-band" path: the parent's
  // managed_subagent tool call is itself blocked awaiting the child, so this
  // answer arrives via the UI/REST while the child waits. Resolves the child's
  // suspended tool call with the response.
  const supervisorAnswerBody = z.object({ response: z.string() });
  fastify.post<{ Params: { requestId: string } }>(
    "/supervisor/:requestId/answer",
    async (request, reply) => {
      const parsed = supervisorAnswerBody.safeParse(request.body);
      if (!parsed.success) return reply.code(400).send({ error: parsed.error.message });
      const ok = answerSupervisor(request.params.requestId, parsed.data.response);
      if (!ok) return reply.code(404).send({ error: "no pending supervisor request with that id" });
      return { ok: true };
    },
  );

  return { cancelChildSupervisorRequests };
}
