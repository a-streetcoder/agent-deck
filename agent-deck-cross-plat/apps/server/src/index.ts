import process from "node:process";
import { startServer } from "./server.ts";

export { startServer, type AgentDeckServer, type StartServerOptions } from "./server.ts";
export { SessionManager, ManagedSession, type CreateSessionOptions } from "./SessionManager.ts";
export { SessionPushBus, type StampedEvent } from "./pushBus.ts";
export { ReceiptBus, type ReceiptName } from "./receipts.ts";
export { SessionIndex, defaultDataDir } from "./persistence.ts";

// CLI entry: `pnpm --filter @agent-deck/server dev`
if (process.argv[1] && import.meta.url.endsWith(process.argv[1].replace(/\\/g, "/"))) {
  const port = Number(process.env.PORT ?? 4200);
  const server = await startServer({ port });
  console.log(`agent-deck server listening on http://127.0.0.1:${server.port}`);
  const shutdown = (): void => {
    void server.close().then(() => process.exit(0));
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}
