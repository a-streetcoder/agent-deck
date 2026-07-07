import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startServer, type AgentDeckServer } from "../src/index.ts";

/**
 * Global instructions routes (native Instructions Global scope 8.4): GET/PUT
 * /runtime/instructions edit ~/.pi/agent/AGENTS.md, which pi loads as global
 * context for every session. The resource home follows AGENT_DECK_PI_ENV.
 */

const resourceHome = mkdtempSync(path.join(tmpdir(), "instructions-home-"));
const dataDir = mkdtempSync(path.join(tmpdir(), "agent-deck-data-"));
let server: AgentDeckServer;

const globalFile = path.join(resourceHome, ".pi", "agent", "AGENTS.md");

async function api(method: string, body?: unknown): Promise<Response> {
  return await fetch(`http://127.0.0.1:${server.port}/runtime/instructions`, {
    method,
    headers: body === undefined ? {} : { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

beforeAll(async () => {
  process.env.AGENT_DECK_PI_ENV = JSON.stringify({ HOME: resourceHome });
  server = await startServer({ dataDir });
});

afterAll(async () => {
  delete process.env.AGENT_DECK_PI_ENV;
  await server.close();
});

describe("global instructions routes", () => {
  it("GET returns empty content + the global AGENTS.md path before anything is written", async () => {
    const { content, path: filePath } = (await (await api("GET")).json()) as {
      content: string;
      path: string;
    };
    expect(content).toBe("");
    expect(filePath).toBe(globalFile);
  });

  it("PUT writes ~/.pi/agent/AGENTS.md (creating the dir) and GET reads it back", async () => {
    const res = await api("PUT", { content: "# Global\n\nBe concise." });
    expect(res.status).toBe(200);
    expect(existsSync(globalFile)).toBe(true);
    expect(readFileSync(globalFile, "utf8")).toContain("Be concise.");

    const { content } = (await (await api("GET")).json()) as { content: string };
    expect(content).toContain("Be concise.");
  });

  it("400s a PUT with no content field", async () => {
    expect((await api("PUT", {})).status).toBe(400);
  });
});
