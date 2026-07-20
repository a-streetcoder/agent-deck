import { Layer, ManagedRuntime } from "effect";
import { describe, expect, it } from "vitest";
import type { ServerRuntime } from "../src/runtime.ts";
import { makeTerminalHost, TerminalHost, type PtyAdapter } from "../src/services/terminal.ts";
import { createTerminalGateway } from "../src/terminalGateway.ts";

/**
 * TerminalGateway unit tests against the fake PTY adapter — specifically the
 * shutdown sweep `closeAll()` (Slice 8 review fix): terminal scopes are
 * detached roots, so the server's close() must be able to kill every
 * still-open PTY deterministically, idempotently with the per-connection
 * teardown.
 */

interface FakePtyRecord {
  kills: Array<string | undefined>;
}

function fakeRuntime(): { runtime: ServerRuntime; ptys: FakePtyRecord[] } {
  const ptys: FakePtyRecord[] = [];
  const adapter: PtyAdapter = {
    spawn: () => {
      const record: FakePtyRecord = { kills: [] };
      ptys.push(record);
      let exitCallback:
        | ((event: { exitCode: number | null; signal: number | null }) => void)
        | null = null;
      return {
        pid: 4242,
        write: () => {},
        resize: () => {},
        kill: (signal) => {
          record.kills.push(signal);
          exitCallback?.({ exitCode: 0, signal: null });
        },
        pause: () => {},
        resume: () => {},
        onData: () => () => {},
        onExit: (callback) => {
          exitCallback = callback;
          return () => {
            exitCallback = null;
          };
        },
      };
    },
  };
  const runtime = ManagedRuntime.make(
    Layer.succeed(TerminalHost, makeTerminalHost(adapter)),
  ) as unknown as ServerRuntime;
  return { runtime, ptys };
}

const spawnOpts = { cwd: process.cwd(), shellCandidates: [{ shell: "fake-shell" }] };

describe("createTerminalGateway", () => {
  it("closeAll() kills every still-open PTY (the shutdown sweep)", async () => {
    const { runtime, ptys } = fakeRuntime();
    const gateway = createTerminalGateway(runtime);
    await gateway.open({ sessionId: "s1", ...spawnOpts });
    await gateway.open({ sessionId: "s2", ...spawnOpts });

    await gateway.closeAll();
    expect(ptys.map((p) => p.kills)).toEqual([["SIGTERM"], ["SIGTERM"]]);

    // Idempotent: a second sweep finds nothing left to kill.
    await gateway.closeAll();
    expect(ptys.map((p) => p.kills)).toEqual([["SIGTERM"], ["SIGTERM"]]);
  });

  it("closeAll() after a per-terminal close() never double-kills (memoized close)", async () => {
    const { runtime, ptys } = fakeRuntime();
    const gateway = createTerminalGateway(runtime);
    const first = await gateway.open({ sessionId: "s1", ...spawnOpts });
    await gateway.open({ sessionId: "s1", ...spawnOpts });

    await first.close();
    expect(ptys[0]!.kills).toEqual(["SIGTERM"]);

    await gateway.closeAll();
    expect(ptys[0]!.kills).toEqual(["SIGTERM"]);
    expect(ptys[1]!.kills).toEqual(["SIGTERM"]);
  });

  it("racing close() and closeAll() share one scope close", async () => {
    const { runtime, ptys } = fakeRuntime();
    const gateway = createTerminalGateway(runtime);
    const opened = await gateway.open({ sessionId: "s1", ...spawnOpts });

    await Promise.all([opened.close(), gateway.closeAll(), opened.close()]);
    expect(ptys[0]!.kills).toEqual(["SIGTERM"]);
  });
});
