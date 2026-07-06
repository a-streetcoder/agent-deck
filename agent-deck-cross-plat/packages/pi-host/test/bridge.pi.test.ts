import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  MOCK_MODEL_ID,
  MOCK_PROVIDER_ID,
  startMockProvider,
  writeMockProviderExtension,
  type MockProviderServer,
} from "@agent-deck/testkit";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { writeBridgeExtension, type BridgeCallRequest } from "../src/bridge.ts";
import { buildLaunchArgs } from "../src/launchPlan.ts";
import { PiSession } from "../src/PiSession.ts";
import { resolvePiBinary } from "../src/resolve.ts";

/**
 * Foundational bridge proof (permanent CI guard): a REAL pi binary advertises
 * an app-managed tool from a generated bridge extension, the model calls it,
 * the tool's execute() round-trips over HTTP to our (stand-in) app endpoint,
 * and the result flows back into the model's next turn. Memory, MCP, and the
 * subagent bridge all sit on exactly this mechanism, so if it breaks they all
 * break — this test exists so that can't happen silently.
 */

const SESSION_ID = "bridge-it-session";

let mock: MockProviderServer;
let bridge: Server;
let session: PiSession;
const bridgeCalls: BridgeCallRequest[] = [];
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const cwd = mkdtempSync(path.join(tmpdir(), "pi-bridge-it-"));

beforeAll(async () => {
  // Stand-in "app-side engine": records each bridge call, echoes the message.
  bridge = createServer((req, res) => {
    let raw = "";
    req.on("data", (chunk) => (raw += chunk));
    req.on("end", () => {
      const call = JSON.parse(raw) as BridgeCallRequest;
      bridgeCalls.push(call);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ content: `echoed: ${String(call.params.message ?? "")}` }));
    });
  });
  await new Promise<void>((resolve) => bridge.listen(0, "127.0.0.1", resolve));
  const endpoint = `http://127.0.0.1:${(bridge.address() as AddressInfo).port}/bridge`;

  // The model calls the bridge tool on the first turn, then answers with text
  // once the tool result is in the transcript (a "tool" role message present).
  mock = await startMockProvider({
    toolCall: (_lastUser, body) => {
      const hasToolResult = body.messages.some((m) => m.role === "tool");
      return hasToolResult ? null : { name: "agent_deck_echo", arguments: { message: "ping" } };
    },
    reply: () => "The echo tool has spoken across the bridge.",
  });

  const mockExt = writeMockProviderExtension(mock.baseUrl);
  const bridgeExt = writeBridgeExtension({
    endpoint,
    sessionId: SESSION_ID,
    token: "test-token",
    tools: [
      {
        name: "agent_deck_echo",
        label: "Echo",
        description: "Echo a message back through the Agent Deck bridge.",
        parameters: {
          type: "object",
          properties: { message: { type: "string", description: "Text to echo." } },
          required: ["message"],
          additionalProperties: false,
        },
      },
    ],
  });

  session = new PiSession({
    binPath: resolvePiBinary().path,
    args: buildLaunchArgs({
      kind: "parent",
      extensions: [mockExt, bridgeExt],
      provider: MOCK_PROVIDER_ID,
      model: MOCK_MODEL_ID,
    }),
    cwd,
    env: { HOME: tmpHome, USERPROFILE: tmpHome, PI_SKIP_VERSION_CHECK: "1" },
    requestTimeoutMs: 45_000,
  });
  session.start();
});

afterAll(async () => {
  await session.stop();
  await mock.close();
  await new Promise<void>((resolve) => bridge.close(() => resolve()));
});

describe("real pi + generated bridge extension: app-managed tool round-trip", () => {
  it("routes a tool call to the app endpoint and feeds the result back to the model", async () => {
    const idle = new Promise<void>((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error(`no idle. stderr: ${session.stderr}`)),
        50_000,
      );
      session.on("event", (piEvent) => {
        if (piEvent.type === "agent_end") {
          clearTimeout(timer);
          resolve();
        }
      });
    });

    await session.prompt("use the echo tool");
    await idle;

    // The bridge endpoint received exactly the call pi should have made.
    expect(bridgeCalls.length).toBe(1);
    expect(bridgeCalls[0]).toMatchObject({
      sessionId: SESSION_ID,
      token: "test-token",
      tool: "agent_deck_echo",
      params: { message: "ping" },
    });
    expect(typeof bridgeCalls[0]!.toolCallId).toBe("string");
    expect(bridgeCalls[0]!.toolCallId.length).toBeGreaterThan(0);

    // pi fed the tool result back to the model: the follow-up provider request
    // carries a "tool" role message with our echoed content.
    expect(mock.requests.length).toBeGreaterThanOrEqual(2);
    const followUp = mock.requests[mock.requests.length - 1]!;
    const toolMessages = followUp.messages.filter((m) => m.role === "tool");
    expect(toolMessages.length).toBeGreaterThan(0);
    expect(JSON.stringify(toolMessages)).toContain("echoed: ping");
  });
});
