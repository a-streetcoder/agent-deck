import { execSync } from "node:child_process";
import { existsSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startServer, type AgentDeckServer } from "@agent-deck/server";
import {
  MOCK_MODEL_ID,
  MOCK_PROVIDER_ID,
  startMockProvider,
  writeMockProviderExtension,
  type MockProviderServer,
} from "@agent-deck/testkit";

const WORKSPACE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const WEB_DIST = path.join(WORKSPACE_ROOT, "apps", "web", "dist");

export interface E2eHarness {
  server: AgentDeckServer;
  mock: MockProviderServer;
  baseUrl: string;
  close(): Promise<void>;
}

/**
 * Boot the full stack for e2e: mock provider → env-configured session defaults
 * → real server serving the built web app. Builds the web app on first use.
 */
export async function startHarness(options?: {
  reply?: (message: string) => string;
  chunkDelayMs?: number;
  /** Extra pi extensions loaded into every UI-created session. */
  extraExtensions?: string[];
}): Promise<E2eHarness> {
  if (!existsSync(path.join(WEB_DIST, "index.html"))) {
    execSync("pnpm --filter @agent-deck/web build", { cwd: WORKSPACE_ROOT, stdio: "inherit" });
  }

  const mock = await startMockProvider({
    reply: options?.reply ? (m) => options.reply!(m) : undefined,
    chunkDelayMs: options?.chunkDelayMs ?? 120,
  });
  const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-e2e-home-"));

  process.env.AGENT_DECK_TEST = "1";
  process.env.AGENT_DECK_DEFAULT_PROVIDER = MOCK_PROVIDER_ID;
  process.env.AGENT_DECK_DEFAULT_MODEL = MOCK_MODEL_ID;
  process.env.AGENT_DECK_DEFAULT_EXTENSIONS = [
    writeMockProviderExtension(mock.baseUrl),
    ...(options?.extraExtensions ?? []),
  ].join(path.delimiter);
  process.env.AGENT_DECK_PI_ENV = JSON.stringify({
    HOME: tmpHome,
    USERPROFILE: tmpHome,
    PI_SKIP_VERSION_CHECK: "1",
  });

  const server = await startServer({
    staticDir: WEB_DIST,
    dataDir: mkdtempSync(path.join(tmpdir(), "agent-deck-e2e-data-")),
  });

  return {
    server,
    mock,
    baseUrl: `http://127.0.0.1:${server.port}`,
    close: async () => {
      await server.close();
      await mock.close();
    },
  };
}
