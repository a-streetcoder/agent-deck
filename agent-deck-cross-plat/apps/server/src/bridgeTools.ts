import { randomUUID } from "node:crypto";
import type { SessionPlanItem } from "@agent-deck/domain";
import { z } from "zod";
import type { BridgeRegistry } from "./bridge.ts";
import type { SessionManager } from "./SessionManager.ts";

/**
 * The deck-agent bridge tools — managed_subagent, managed_parallel, and the
 * session activity plan — registered on the app bridge at startup. Moved
 * verbatim from server.ts (Slice 2 decomposition).
 */
export function registerDeckBridgeTools(bridge: BridgeRegistry, sessions: SessionManager): void {
  // Native subagents (native-subagent-bridge.md): a parent session can launch a
  // focused child pi to complete one task and report back. v1 is text-returning
  // (managed_subagent); parallel / supervisor / plan tools + the deck UI follow.
  const subagentParams = z.object({
    task: z.string().trim().min(1),
    agent: z.string().trim().min(1).optional(),
  });
  bridge.register(
    {
      name: "managed_subagent",
      label: "Subagent",
      description:
        "Delegate a self-contained task to a fresh subagent (no conversation history) and get its result back. Use for focused, independent work you can hand off with a complete task description. Optionally pass `agent` to delegate to one of your installed named agents (it adopts that agent's persona).",
      parameters: {
        type: "object",
        properties: {
          task: {
            type: "string",
            description: "A complete, self-contained description of the task for the subagent.",
          },
          agent: {
            type: "string",
            description:
              "Optional: the name of an installed agent to delegate to; the subagent adopts its persona. Omit for a plain anonymous subagent.",
          },
        },
        required: ["task"],
        additionalProperties: false,
      },
      promptSnippet: "managed_subagent — delegate a self-contained task to a fresh subagent.",
    },
    async (params, ctx) => {
      const parsed = subagentParams.safeParse(params);
      if (!parsed.success) {
        return {
          content: `Invalid managed_subagent arguments: ${parsed.error.message}`,
          isError: true,
        };
      }
      try {
        const result = await sessions.runSubagent(
          ctx.sessionId,
          parsed.data.task,
          parsed.data.agent,
        );
        return { content: result || "(the subagent returned no output)" };
      } catch (error) {
        return { content: `Subagent failed: ${String(error)}`, isError: true };
      }
    },
  );

  // Fan out several subagents at once. Each runs as its own child pi; the count
  // is capped so a single call can't spawn an unbounded number of processes.
  const parallelParams = z.object({
    tasks: z
      .array(
        // `.strict()` matches the item schema's additionalProperties:false, so an
        // unexpected field is rejected rather than silently stripped.
        z
          .object({
            task: z.string().trim().min(1),
            agent: z.string().trim().min(1).optional(),
          })
          .strict(),
      )
      .min(1)
      .max(8),
  });
  bridge.register(
    {
      name: "managed_parallel",
      label: "Parallel subagents",
      description:
        "Run several self-contained tasks in parallel, each in its own fresh subagent, and get all their results back together. Use when the tasks are independent. Each task may optionally name an `agent` to delegate to (it adopts that agent's persona).",
      parameters: {
        type: "object",
        properties: {
          tasks: {
            type: "array",
            items: {
              type: "object",
              properties: {
                task: {
                  type: "string",
                  description: "A complete, self-contained task description.",
                },
                agent: {
                  type: "string",
                  description:
                    "Optional: the name of an installed agent to delegate this task to; the subagent adopts its persona.",
                },
              },
              required: ["task"],
              additionalProperties: false,
            },
            minItems: 1,
            maxItems: 8,
            description: "Independent, self-contained tasks to run in parallel (max 8).",
          },
        },
        required: ["tasks"],
        additionalProperties: false,
      },
      promptSnippet: "managed_parallel — run several independent tasks in parallel subagents.",
    },
    async (params, ctx) => {
      const parsed = parallelParams.safeParse(params);
      if (!parsed.success) {
        return {
          content: `Invalid managed_parallel arguments: ${parsed.error.message}`,
          isError: true,
        };
      }
      // allSettled: one failing subagent doesn't drop the others' results.
      const settled = await Promise.allSettled(
        parsed.data.tasks.map((t) => sessions.runSubagent(ctx.sessionId, t.task, t.agent)),
      );
      const anyOk = settled.some((r) => r.status === "fulfilled");
      const rendered = settled
        .map((result, index) => {
          const label = `### Subagent ${index + 1}`;
          return result.status === "fulfilled"
            ? `${label}\n${result.value || "(no output)"}`
            : `${label} (failed)\n${String(result.reason)}`;
        })
        .join("\n\n");
      return { content: rendered, isError: !anyOk };
    },
  );

  // Session activity plan (native activity-sidebar "Plan"): a PARENT agent
  // maintains a per-session checklist. set_session_plan REPLACES the list;
  // update_session_plan patches items by id. The plan rides the session's push
  // bus as domain state (plan_set / plan_update), so clients mirror it.
  const planStatus = z.enum(["todo", "in_progress", "done", "blocked", "skipped"]);
  const setPlanParams = z.object({
    items: z
      .array(
        z.object({
          id: z.string().trim().min(1).optional(),
          title: z.string().trim().min(1),
          status: planStatus.optional(),
        }),
      )
      .max(50),
  });
  const updatePlanParams = z.object({
    updates: z
      .array(
        z.object({
          id: z.string().trim().min(1),
          title: z.string().trim().min(1).optional(),
          status: planStatus.optional(),
        }),
      )
      .min(1)
      .max(50),
  });
  const renderPlan = (items: SessionPlanItem[]): string =>
    items.length === 0
      ? "(empty plan)"
      : items.map((it) => `- [${it.status}] ${it.id}: ${it.title}`).join("\n");
  bridge.register(
    {
      name: "set_session_plan",
      label: "Set plan",
      description:
        "Set (replace) this session's activity plan — a short checklist of the steps you'll take. Each item has a title and an optional status (todo/in_progress/done/blocked/skipped, default todo). The result lists each item's assigned id; use those ids with update_session_plan.",
      parameters: {
        type: "object",
        properties: {
          items: {
            type: "array",
            maxItems: 50,
            items: {
              type: "object",
              properties: {
                id: { type: "string", description: "Optional stable id; assigned if omitted." },
                title: { type: "string" },
                status: {
                  type: "string",
                  enum: ["todo", "in_progress", "done", "blocked", "skipped"],
                },
              },
              required: ["title"],
              additionalProperties: false,
            },
          },
        },
        required: ["items"],
        additionalProperties: false,
      },
      promptSnippet: "set_session_plan — set/replace the session's activity plan checklist.",
    },
    (params, ctx) => {
      const parsed = setPlanParams.safeParse(params);
      if (!parsed.success) {
        return {
          content: `Invalid set_session_plan arguments: ${parsed.error.message}`,
          isError: true,
        };
      }
      const session = sessions.get(ctx.sessionId);
      if (!session) return { content: "No such session for the plan.", isError: true };
      // Ids MUST be unique: a duplicate id would make update_session_plan patch
      // every matching item and collides React keys in the panel. Coin a fresh
      // id for anything missing or duplicated.
      const seen = new Set<string>();
      const items: SessionPlanItem[] = parsed.data.items.map((it) => {
        let id = it.id ?? randomUUID();
        if (seen.has(id)) id = randomUUID();
        seen.add(id);
        return { id, title: it.title, status: it.status ?? "todo" };
      });
      session.setPlan(items);
      return { content: `Plan set (${items.length} item(s)):\n${renderPlan(items)}` };
    },
  );
  bridge.register(
    {
      name: "update_session_plan",
      label: "Update plan",
      description:
        "Update items in this session's activity plan by id (from set_session_plan). Each update carries an id and a new status and/or title. Unknown ids are ignored.",
      parameters: {
        type: "object",
        properties: {
          updates: {
            type: "array",
            minItems: 1,
            maxItems: 50,
            items: {
              type: "object",
              properties: {
                id: { type: "string" },
                title: { type: "string" },
                status: {
                  type: "string",
                  enum: ["todo", "in_progress", "done", "blocked", "skipped"],
                },
              },
              required: ["id"],
              additionalProperties: false,
            },
          },
        },
        required: ["updates"],
        additionalProperties: false,
      },
      promptSnippet: "update_session_plan — patch plan items by id (status/title).",
    },
    (params, ctx) => {
      const parsed = updatePlanParams.safeParse(params);
      if (!parsed.success) {
        return {
          content: `Invalid update_session_plan arguments: ${parsed.error.message}`,
          isError: true,
        };
      }
      const session = sessions.get(ctx.sessionId);
      if (!session) return { content: "No such session for the plan.", isError: true };
      session.updatePlan(parsed.data.updates);
      return { content: `Plan updated.\n${renderPlan(session.plan)}` };
    },
  );
}
