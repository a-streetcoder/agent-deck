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
 * Named subagents: `managed_subagent{task, agent}` delegates to one of the
 * project's installed agents. The child adopts that agent's persona (its body is
 * COMPOSED into the subagent operating prompt, never replacing it), and the
 * Subagent cell records the agent name. An unknown agent fails cleanly.
 */

process.env.AGENT_DECK_TEST = "1";

const PERSONA_SENTINEL = "PERSONA_SENTINEL: You are Reviewer Bot, a meticulous code reviewer.";

let mock: MockProviderServer;
let server: AgentDeckServer;
let projectId: string;
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const project = mkdtempSync(path.join(tmpdir(), "pi-named-subagent-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));

function systemText(request: ChatCompletionRequest): string {
  return request.messages
    .filter((m) => m.role === "developer" || m.role === "system")
    .map((m) => (typeof m.content === "string" ? m.content : JSON.stringify(m.content)))
    .join("\n");
}

/** The child is identifiable by its subagent operating prompt. */
function isChildRequest(body: ChatCompletionRequest): boolean {
  return systemText(body).includes("focused subagent launched by Agent Deck");
}

beforeAll(async () => {
  mock = await startMockProvider({
    // The PARENT delegates (never the child, never after the tool result lands).
    // "use-ghost" in the prompt exercises the unknown-agent path.
    toolCall: (lastUser, body) => {
      if (isChildRequest(body) || body.messages.some((m) => m.role === "tool")) return null;
      const agent = lastUser.includes("use-ghost") ? "ghost-bot" : "reviewer-bot";
      return { name: "managed_subagent", arguments: { task: "Review the diff.", agent } };
    },
    reply: (_lastUser, body) =>
      isChildRequest(body) ? "CHILD_REVIEW_SENTINEL: looks good." : "Delegated and done.",
  });
  process.env.AGENT_DECK_PROVIDER_EXTENSIONS = writeMockProviderExtension(mock.baseUrl);

  // A named project agent with a distinctive persona body.
  const agentsDir = path.join(project, ".pi", "agents");
  mkdirSync(agentsDir, { recursive: true });
  writeFileSync(
    path.join(agentsDir, "reviewer-bot.md"),
    `---\nname: reviewer-bot\ndescription: Meticulous reviewer\n---\n\n${PERSONA_SENTINEL}\n`,
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

async function startSession(): Promise<string> {
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
  return session.id;
}

describe("managed_subagent{agent}: named delegation", () => {
  it("composes the named agent's persona into the child and records the name on the cell", async () => {
    const id = await startSession();
    await server.sessions.get(id)!.prompt("delegate a code review");
    await server.receipts.waitFor("idle", id);

    // The child ran with the agent's persona COMPOSED IN — its system prompt has
    // both the agent body AND the subagent operating prompt (not replaced).
    const childRequest = mock.requests.find(isChildRequest);
    expect(childRequest).toBeDefined();
    const childSystem = systemText(childRequest!);
    expect(childSystem).toContain(PERSONA_SENTINEL);
    expect(childSystem).toContain("focused subagent launched by Agent Deck");

    // The Subagent cell in the parent transcript records which agent it used.
    const cells = server.sessions
      .get(id)!
      .snapshot()
      .state.cells.filter((c): c is SubagentCell => c.kind === "subagent");
    expect(cells).toHaveLength(1);
    expect(cells[0]!.agentName).toBe("reviewer-bot");
  });

  it("surfaces a clean error when the named agent does not exist", async () => {
    const id = await startSession();
    await server.sessions.get(id)!.prompt("delegate but use-ghost");
    await server.receipts.waitFor("idle", id);

    // No child ever launched for this session's ghost delegation, and the parent
    // got the failure back as the tool result.
    const followUp = mock.requests[mock.requests.length - 1]!;
    const toolText = JSON.stringify(followUp.messages.filter((m) => m.role === "tool"));
    expect(toolText).toContain("unknown agent: ghost-bot");
  });
});
