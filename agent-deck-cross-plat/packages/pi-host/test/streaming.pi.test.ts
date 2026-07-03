import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  createIngestState,
  emptyTranscript,
  ingestPiEvent,
  reduceTranscript,
  type DomainEvent,
  type TranscriptState,
} from "@agent-deck/domain";
import {
  MOCK_MODEL_ID,
  MOCK_PROVIDER_ID,
  startMockProvider,
  writeMockProviderExtension,
  type MockProviderServer,
} from "@agent-deck/testkit";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { buildLaunchArgs } from "../src/launchPlan.ts";
import { PiSession } from "../src/PiSession.ts";
import { resolvePiBinary } from "../src/resolve.ts";

/**
 * THE non-negotiable of this port, as a permanent CI test: a REAL pi binary,
 * talking to a deterministic mock provider, must yield MULTIPLE distinct
 * cell_delta domain events before the final cell — i.e. streaming actually
 * streams. (Attempt #1 dropped text_delta events; this test exists so that
 * can never happen silently again.)
 */

const SCRIPTED_REPLY = "Streaming works one word at a time across the bridge tonight";

let mock: MockProviderServer;
let session: PiSession;
const tmpHome = mkdtempSync(path.join(tmpdir(), "pi-home-"));
const cwd = mkdtempSync(path.join(tmpdir(), "pi-stream-it-"));

beforeAll(async () => {
  mock = await startMockProvider({ reply: () => SCRIPTED_REPLY });
  const extension = writeMockProviderExtension(mock.baseUrl);
  session = new PiSession({
    binPath: resolvePiBinary().path,
    args: buildLaunchArgs({
      kind: "parent",
      extensions: [extension],
      provider: MOCK_PROVIDER_ID,
      model: MOCK_MODEL_ID,
    }),
    cwd,
    // Hermetic HOME: no user settings/auth/sessions are read or written.
    env: {
      HOME: tmpHome,
      USERPROFILE: tmpHome,
      PI_SKIP_VERSION_CHECK: "1",
    },
    requestTimeoutMs: 45_000,
  });
  session.start();
});

afterAll(async () => {
  await session.stop();
  await mock.close();
});

describe("real pi + mock provider: streaming passthrough", () => {
  it("emits multiple distinct cell_deltas before the final assistant cell", async () => {
    const ingest = createIngestState();
    const domainEvents: DomainEvent[] = [];
    let state: TranscriptState = emptyTranscript();

    const idle = new Promise<void>((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error(`no agent_end. stderr: ${session.stderr}`)),
        50_000,
      );
      session.on("event", (piEvent) => {
        for (const domainEvent of ingestPiEvent(ingest, piEvent)) {
          domainEvents.push(domainEvent);
          state = reduceTranscript(state, domainEvent);
          if (domainEvent.type === "agent_status" && domainEvent.status === "idle") {
            clearTimeout(timer);
            resolve();
          }
        }
      });
    });

    await session.prompt("hello, stream to me");
    await idle;

    const finalIndex = domainEvents.findIndex(
      (e) => e.type === "cell_final" && e.cell.kind === "assistant",
    );
    const deltasBeforeFinal = domainEvents
      .slice(0, finalIndex)
      .filter((e) => e.type === "cell_delta");

    // The enshrined assertion: streaming is visibly incremental.
    expect(finalIndex).toBeGreaterThan(-1);
    expect(deltasBeforeFinal.length).toBeGreaterThanOrEqual(2);
    expect(deltasBeforeFinal.map((e) => e.delta).join("")).toBe(SCRIPTED_REPLY);

    // The final transcript is authoritative and matches the script.
    const assistant = state.cells.find((c) => c.kind === "assistant");
    expect(assistant).toMatchObject({
      streaming: false,
      blocks: [{ kind: "text", text: SCRIPTED_REPLY, done: true }],
    });
    const user = state.cells.find((c) => c.kind === "user");
    expect(user).toMatchObject({ text: "hello, stream to me" });

    // The mock provider actually served the request (real HTTP round-trip).
    expect(mock.requests.length).toBeGreaterThan(0);
    expect(mock.requests[0]!.model).toBe(MOCK_MODEL_ID);
  });
});
