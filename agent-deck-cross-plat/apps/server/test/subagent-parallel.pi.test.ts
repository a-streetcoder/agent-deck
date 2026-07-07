import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  MOCK_MODEL_ID,
  MOCK_PROVIDER_ID,
  startMockProvider,
  writeMockProviderExtension,
  type ChatCompletionRequest,
  type MockProviderServer,
} from "@agent-deck/testkit";
import type { SubagentCell } from "@agent-deck/domain";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * managed_parallel end-to-end against real pi: a parent fans out two tasks; two
 * child pi sessions run concurrently, each producing a task-specific result, and
 * the parent receives BOTH combined in the tool result. One task delegates to a
 * NAMED agent (per-task `agent`) — that child adopts the agent's persona.
 */

process.env.AGENT_DECK_TEST = "1";

const PERSONA_SENTINEL = "PERSONA_SENTINEL: You are Reviewer Bot.";

let mock: MockProviderServer;
let server: AgentDeckServer;
let projectId: string;
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const project = mkdtempSync(path.join(tmpdir(), "pi-parallel-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));

function systemText(request: ChatCompletionRequest): string {
  return request.messages
    .filter((m) => m.role === "developer" || m.role === "system")
    .map((m) => (typeof m.content === "string" ? m.content : JSON.stringify(m.content)))
    .join("\n");
}

function isChildRequest(body: ChatCompletionRequest): boolean {
  return systemText(body).includes("focused subagent launched by Agent Deck");
}

beforeAll(async () => {
  mock = await startMockProvider({
    toolCall: (_lastUser, body) => {
      if (isChildRequest(body) || body.messages.some((m) => m.role === "tool")) return null;
      // The BETA task delegates to the named reviewer-bot; ALPHA is anonymous.
      return {
        name: "managed_parallel",
        arguments: {
          tasks: [
            { task: "TASK_ALPHA: analyze alpha" },
            { task: "TASK_BETA: analyze beta", agent: "reviewer-bot" },
          ],
        },
      };
    },
    // Each child is identified by its task text in the system prompt.
    reply: (_lastUser, body) => {
      const sys = systemText(body);
      if (sys.includes("TASK_ALPHA")) return "RESULT_ALPHA_SENTINEL";
      if (sys.includes("TASK_BETA")) return "RESULT_BETA_SENTINEL";
      return "Delegated to parallel subagents.";
    },
  });
  process.env.AGENT_DECK_PROVIDER_EXTENSIONS = writeMockProviderExtension(mock.baseUrl);

  // A named project agent the BETA task delegates to.
  const agentsDir = path.join(project, ".pi", "agents");
  mkdirSync(agentsDir, { recursive: true });
  writeFileSync(
    path.join(agentsDir, "reviewer-bot.md"),
    `---\nname: reviewer-bot\ndescription: Reviewer\n---\n\n${PERSONA_SENTINEL}\n`,
  );

  server = await startServer({ dataDir });
  const created = (await (
    await fetch(`http://127.0.0.1:${server.port}/projects`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path: project }),
    })
  ).json()) as { project: { id: string } };
  projectId = created.project.id;
});

afterAll(async () => {
  await server.close();
  await mock.close();
  delete process.env.AGENT_DECK_PROVIDER_EXTENSIONS;
});

describe("managed_parallel: fan out subagents and combine results", () => {
  it("runs two children concurrently and returns both results to the parent", async () => {
    const response = await fetch(`http://127.0.0.1:${server.port}/sessions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        cwd: project,
        projectId,
        provider: MOCK_PROVIDER_ID,
        model: MOCK_MODEL_ID,
        extensions: [process.env.AGENT_DECK_PROVIDER_EXTENSIONS],
        env: { HOME: tmpHome, USERPROFILE: tmpHome, PI_SKIP_VERSION_CHECK: "1" },
      }),
    });
    expect(response.status).toBe(201);
    const { session } = (await response.json()) as { session: { id: string } };

    await server.sessions.get(session.id)!.prompt("run both analyses in parallel");
    await server.receipts.waitFor("idle", session.id);

    // Both child tasks actually ran (two distinct child requests hit the provider).
    const childSystems = mock.requests.filter(isChildRequest).map(systemText);
    expect(childSystems.some((s) => s.includes("TASK_ALPHA"))).toBe(true);
    expect(childSystems.some((s) => s.includes("TASK_BETA"))).toBe(true);

    // The BETA task delegated to reviewer-bot, so ITS child adopted the persona;
    // the ALPHA (anonymous) child did not.
    const betaChild = childSystems.find((s) => s.includes("TASK_BETA"))!;
    const alphaChild = childSystems.find((s) => s.includes("TASK_ALPHA"))!;
    expect(betaChild).toContain(PERSONA_SENTINEL);
    expect(alphaChild).not.toContain(PERSONA_SENTINEL);

    // The parent received BOTH results, combined in the tool result.
    const followUp = mock.requests[mock.requests.length - 1]!;
    const toolText = JSON.stringify(followUp.messages.filter((m) => m.role === "tool"));
    expect(toolText).toContain("RESULT_ALPHA_SENTINEL");
    expect(toolText).toContain("RESULT_BETA_SENTINEL");

    // Two subagent cells; exactly the named one records agentName.
    const cells = server.sessions
      .get(session.id)!
      .snapshot()
      .state.cells.filter((c): c is SubagentCell => c.kind === "subagent");
    expect(cells).toHaveLength(2);
    expect(cells.filter((c) => c.agentName === "reviewer-bot")).toHaveLength(1);
    expect(cells.filter((c) => c.agentName === undefined)).toHaveLength(1);
  });
});
