import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { ProviderLoginManager } from "../src/providerLogin.ts";

/**
 * The login relay state machine, hermetic: AuthStorage.login is injected as a
 * scripted flow, so the push (progress/device-code) + pull (prompt/select)
 * protocol is exercised without a real OAuth provider.
 */

function roots() {
  return { home: mkdtempSync(path.join(tmpdir(), "login-home-")) };
}
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

describe("provider login relay", () => {
  it("relays progress + device code, parks on a prompt, and completes on the response", async () => {
    let seenAnswer: string | undefined;
    const manager = new ProviderLoginManager(async (_authPath, _providerId, cb) => {
      cb.onProgress?.("Contacting provider…");
      cb.onDeviceCode({ userCode: "WXYZ-1234", verificationUri: "https://example.test/device" });
      seenAnswer = await cb.onPrompt({ message: "Paste the code from your browser" });
      if (seenAnswer !== "hunter2") throw new Error("wrong code");
    });

    const id = manager.start(roots(), "anthropic");
    // The synchronous prologue is queued: progress, device_code, then a parked prompt.
    let poll = manager.poll(id, 0)!;
    expect(poll.events.map((e) => e.type)).toEqual(["progress", "device_code", "prompt"]);
    expect(poll.status).toBe("running");
    const device = poll.events[1];
    expect(device).toMatchObject({
      userCode: "WXYZ-1234",
      verificationUri: "https://example.test/device",
    });

    // Respond → the parked login resumes and finishes.
    expect(manager.respond(id, "hunter2")).toBe(true);
    await tick();
    poll = manager.poll(id, poll.nextCursor)!;
    expect(seenAnswer).toBe("hunter2");
    expect(poll.events.at(-1)).toEqual({ type: "done", ok: true });
    expect(poll.status).toBe("done");
  });

  it("surfaces a failed login as done:false with the error", async () => {
    const manager = new ProviderLoginManager(async (_authPath, _providerId, cb) => {
      await cb.onPrompt({ message: "Code?" });
      throw new Error("invalid_grant");
    });
    const id = manager.start(roots(), "anthropic");
    manager.respond(id, "nope");
    await tick();
    const poll = manager.poll(id, 0)!;
    expect(poll.status).toBe("error");
    expect(poll.events.at(-1)).toEqual({ type: "done", ok: false, error: "invalid_grant" });
  });

  it("relays a select and returns the chosen option id", async () => {
    let chosen: string | undefined;
    const manager = new ProviderLoginManager(async (_authPath, _providerId, cb) => {
      chosen = await cb.onSelect({
        message: "Which account?",
        options: [
          { id: "team", label: "Team" },
          { id: "personal", label: "Personal" },
        ],
      });
    });
    const id = manager.start(roots(), "github-copilot");
    const poll = manager.poll(id, 0)!;
    expect(poll.events[0]).toMatchObject({ type: "select", message: "Which account?" });
    manager.respond(id, "personal");
    await tick();
    expect(chosen).toBe("personal");
    expect(manager.poll(id, 0)!.status).toBe("done");
  });

  it("respond is a no-op when nothing is pending, and unknown ids poll undefined", () => {
    const manager = new ProviderLoginManager(async () => {});
    expect(manager.poll("nope", 0)).toBeUndefined();
    const id = manager.start(roots(), "anthropic");
    expect(manager.respond(id, "x")).toBe(false); // no prompt was requested
  });
});
