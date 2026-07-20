import { existsSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { isMainModule } from "./mainModule.ts";
import { startServer } from "./server.ts";

export { startServer, type AgentDeckServer, type StartServerOptions } from "./server.ts";
export { SessionManager, ManagedSession, type CreateSessionOptions } from "./SessionManager.ts";
export { SessionPushBus, type StampedEvent } from "./pushBus.ts";
export { ReceiptBus, type ReceiptName } from "./receipts.ts";
export { SessionIndex, defaultDataDir } from "./persistence.ts";

// CLI entry: `pnpm --filter @agent-deck/server dev`
if (isMainModule(import.meta.url, process.argv[1])) {
  const port = Number(process.env.PORT ?? 4200);

  // Serve the built web app at / by default (apps/web/dist).
  const webDist = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../web/dist");
  const hasWebBuild = existsSync(path.join(webDist, "index.html"));
  if (!hasWebBuild) {
    console.warn(
      "No web build found — API only. Build the UI first:\n  pnpm --filter @agent-deck/web build",
    );
  }

  const server = await startServer({
    port,
    staticDir: hasWebBuild ? webDist : undefined,
    // Lets the desktop shell (and tests) point persistence at an isolated dir.
    dataDir: process.env.AGENT_DECK_DATA_DIR || undefined,
  });
  console.log(`agent-deck listening on http://127.0.0.1:${server.port}`);
  const shutdown = (): void => {
    void server.close().then(() => process.exit(0));
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}
