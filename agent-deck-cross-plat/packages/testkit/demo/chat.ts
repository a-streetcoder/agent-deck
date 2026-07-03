/**
 * Terminal streaming demo: real pi + the mock provider, no UI, no API keys.
 * Run from the workspace root:  pnpm demo:chat [-- "your message"]
 *
 * Purpose: eyeball that streaming is genuinely incremental before any web UI
 * exists (plan slice 3). Each delta prints as it arrives.
 */
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import process from "node:process";
import { createIngestState, ingestPiEvent } from "@agent-deck/domain";
import { buildLaunchArgs, PiSession, resolvePiBinary } from "@agent-deck/pi-host";
import {
  MOCK_MODEL_ID,
  MOCK_PROVIDER_ID,
  startMockProvider,
  writeMockProviderExtension,
} from "../src/index.ts";

const message = process.argv[2] ?? "Hello from the demo harness — stream me something.";

const mock = await startMockProvider({ chunkDelayMs: 80 });
const extension = writeMockProviderExtension(mock.baseUrl);
const resolved = resolvePiBinary();
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-demo-home-"));

console.log(`pi: ${resolved.path} (${resolved.source})`);
console.log(`mock provider: ${mock.baseUrl}`);
console.log(`> ${message}\n`);

const session = new PiSession({
  binPath: resolved.path,
  args: buildLaunchArgs({
    kind: "parent",
    extensions: [extension],
    provider: MOCK_PROVIDER_ID,
    model: MOCK_MODEL_ID,
  }),
  cwd: process.cwd(),
  env: { HOME: tmpHome, USERPROFILE: tmpHome, PI_SKIP_VERSION_CHECK: "1" },
});

const ingest = createIngestState();
session.on("event", (piEvent) => {
  for (const domainEvent of ingestPiEvent(ingest, piEvent)) {
    switch (domainEvent.type) {
      case "cell_delta":
        process.stdout.write(domainEvent.delta);
        break;
      case "cell_final":
        if (domainEvent.cell.kind === "assistant") process.stdout.write("\n");
        break;
      case "agent_status":
        if (domainEvent.status === "idle") {
          void session.stop().then(() => mock.close());
        }
        break;
      default:
        break;
    }
  }
});

session.start();
await session.prompt(message);
