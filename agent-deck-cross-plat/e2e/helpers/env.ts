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
  /** The hermetic HOME the pi subprocesses (and resource scanner) use. */
  piHome: string;
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
  /** Drive a real pi tool call (e.g. read/bash) — see MockProviderOptions.toolCall. */
  toolCall?: NonNullable<Parameters<typeof startMockProvider>[0]>["toolCall"];
}): Promise<E2eHarness> {
  if (!existsSync(path.join(WEB_DIST, "index.html"))) {
    execSync("pnpm --filter @agent-deck/web build", { cwd: WORKSPACE_ROOT, stdio: "inherit" });
  }

  const mock = await startMockProvider({
    reply: options?.reply ? (m) => options.reply!(m) : undefined,
    toolCall: options?.toolCall,
    chunkDelayMs: options?.chunkDelayMs ?? 120,
  });
  const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-e2e-home-"));

  const providerExtension = writeMockProviderExtension(mock.baseUrl);
  process.env.AGENT_DECK_TEST = "1";
  // Default (no-project) sessions run in a hermetic temp dir instead of the
  // e2e process's own checkout — which is inside THIS git repo, so without the
  // seam every default session would carry the dev tree's changed-file set
  // into the Slice-10 diff surface (nondeterministic badges/baselines).
  process.env.AGENT_DECK_DEFAULT_CWD = mkdtempSync(path.join(tmpdir(), "agent-deck-e2e-cwd-"));
  process.env.AGENT_DECK_DEFAULT_PROVIDER = MOCK_PROVIDER_ID;
  process.env.AGENT_DECK_DEFAULT_MODEL = MOCK_MODEL_ID;
  process.env.AGENT_DECK_DEFAULT_EXTENSIONS = [
    providerExtension,
    ...(options?.extraExtensions ?? []),
  ].join(path.delimiter);
  // Helper launches (titles) load ONLY the provider registration.
  process.env.AGENT_DECK_PROVIDER_EXTENSIONS = providerExtension;
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
    piHome: tmpHome,
    close: async () => {
      await server.close();
      await mock.close();
    },
  };
}
