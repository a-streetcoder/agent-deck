import { mkdtempSync } from "node:fs";
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
import type { SubagentCell, SupervisorQuestionCell } from "@agent-deck/domain";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * Blocking supervisor requests (native-subagent-bridge.md): a child subagent
 * calls contact_supervisor{method:"need_decision"}, which SUSPENDS the child; the
 * server surfaces it as an interactive card on the PARENT and the answer
 * (delivered out-of-band via POST /supervisor/:id/answer, since the parent's own
 * managed_subagent call is blocked) resolves the child's tool call so it
 * continues to a final result.
 */

process.env.AGENT_DECK_TEST = "1";

let mock: MockProviderServer;
let server: AgentDeckServer;
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const cwd = mkdtempSync(path.join(tmpdir(), "pi-supervisor-block-"));
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

const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => {
    setTimeout(resolve, ms);
  });

beforeAll(async () => {
  mock = await startMockProvider({
    toolCall: (_lastUser, body) => {
      const hasToolResult = body.messages.some((m) => m.role === "tool");
      if (isChildRequest(body)) {
        // The child asks a blocking question, then (after the answer) replies.
        return hasToolResult
          ? null
          : {
              name: "contact_supervisor",
              arguments: {
                method: "need_decision",
                title: "Which format?",
                message: "DECISION_SENTINEL: should the output be JSON or YAML?",
                options: ["JSON", "YAML"],
              },
            };
      }
      return hasToolResult
        ? null
        : { name: "managed_subagent", arguments: { task: "Produce the output." } };
    },
    reply: (_lastUser, body) =>
      isChildRequest(body) ? "CHILD_DONE_SENTINEL: produced." : "Delegated and done.",
  });
  process.env.AGENT_DECK_PROVIDER_EXTENSIONS = writeMockProviderExtension(mock.baseUrl);
  server = await startServer({ dataDir });
});

afterAll(async () => {
  await server.close();
  await mock.close();
  delete process.env.AGENT_DECK_PROVIDER_EXTENSIONS;
});

describe("contact_supervisor blocking: a child suspends on need_decision until answered", () => {
  it("surfaces the request on the parent, and the answer resolves the child's tool call", async () => {
    const response = await fetch(`http://127.0.0.1:${server.port}/sessions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        cwd,
        provider: MOCK_PROVIDER_ID,
        model: MOCK_MODEL_ID,
        extensions: [process.env.AGENT_DECK_PROVIDER_EXTENSIONS],
        env: { HOME: tmpHome, USERPROFILE: tmpHome, PI_SKIP_VERSION_CHECK: "1" },
      }),
    });
    expect(response.status).toBe(201);
    const { session } = (await response.json()) as { session: { id: string } };
    const managed = server.sessions.get(session.id)!;

    // prompt() acks fast; the turn (and the blocked child) runs async.
    await managed.prompt("delegate with a decision point");

    // The child suspends; poll the parent transcript for the interactive card.
    let question: SupervisorQuestionCell | undefined;
    for (let i = 0; i < 200 && !question; i++) {
      question = managed
        .snapshot()
        .state.cells.find((c): c is SupervisorQuestionCell => c.kind === "supervisor_question");
      if (!question) await sleep(50);
    }
    expect(question).toBeDefined();
    expect(question!.method).toBe("need_decision");
    expect(question!.title).toBe("Which format?");
    expect(question!.options).toEqual(["JSON", "YAML"]);
    expect(question!.answered).toBe(false);

    // The request is pending server-side (not yet answered).
    const pending = server.supervisor.list(session.id).find((r) => r.id === question!.requestId);
    expect(pending?.status).toBe("pending");

    // Deliver the answer out-of-band (the parent's managed_subagent call is blocked).
    const answerRes = await fetch(
      `http://127.0.0.1:${server.port}/supervisor/${question!.requestId}/answer`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ response: "ANSWER_SENTINEL: use JSON" }),
      },
    );
    expect(answerRes.status).toBe(200);

    // The child resumes and the whole turn completes.
    await server.receipts.waitFor("idle", session.id);

    // The card is now answered with the response, and the record is answered.
    const answered = managed
      .snapshot()
      .state.cells.find((c): c is SupervisorQuestionCell => c.kind === "supervisor_question")!;
    expect(answered.answered).toBe(true);
    expect(answered.answer).toBe("ANSWER_SENTINEL: use JSON");
    expect(
      server.supervisor.list(session.id).find((r) => r.id === question!.requestId)?.status,
    ).toBe("answered");

    // The child RECEIVED the answer as its contact_supervisor tool result: the
    // child request after the tool call carries it in a role:"tool" message.
    const childToolResults = mock.requests
      .filter((r) => isChildRequest(r) && r.messages.some((m) => m.role === "tool"))
      .map((r) => JSON.stringify(r.messages.filter((m) => m.role === "tool")));
    expect(childToolResults.some((t) => t.includes("ANSWER_SENTINEL: use JSON"))).toBe(true);

    // The subagent finished and the parent received the child's final result.
    const subagent = managed
      .snapshot()
      .state.cells.find((c): c is SubagentCell => c.kind === "subagent")!;
    expect(subagent.status).toBe("done");
    expect(subagent.text).toContain("CHILD_DONE_SENTINEL: produced.");
    const followUp = mock.requests[mock.requests.length - 1]!;
    expect(JSON.stringify(followUp.messages.filter((m) => m.role === "tool"))).toContain(
      "CHILD_DONE_SENTINEL: produced.",
    );
  });
});
