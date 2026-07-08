import { afterEach, describe, expect, it } from "vitest";
import { McpLoopbackServer } from "../src/mcpLoopback.ts";

/**
 * The one-shot loopback redirect catcher (native MCPLoopbackServer). Hermetic:
 * a real 127.0.0.1 server is started and a real fetch stands in for the browser
 * redirect — no OAuth provider needed.
 */

let server: McpLoopbackServer | undefined;

afterEach(async () => {
  await server?.close();
  server = undefined;
});

describe("McpLoopbackServer", () => {
  it("captures the redirect's code + state and answers with a close-me page", async () => {
    server = new McpLoopbackServer();
    const port = await server.start();
    expect(server.redirectUrl).toBe(`http://127.0.0.1:${port}/callback`);

    const waiting = server.waitForCallback(5000);
    const res = await fetch(`http://127.0.0.1:${port}/callback?code=the-code&state=the-state`);
    expect(res.status).toBe(200);
    expect(await res.text()).toContain("close this tab");

    expect(await waiting).toEqual({ code: "the-code", state: "the-state", error: undefined });
  });

  it("buffers a callback that arrives BEFORE waitForCallback is called", async () => {
    server = new McpLoopbackServer();
    const port = await server.start();
    await fetch(`http://127.0.0.1:${port}/callback?code=early&state=s`);
    // Wait is called only now — the earlier result is still delivered.
    expect(await server.waitForCallback(5000)).toEqual({
      code: "early",
      state: "s",
      error: undefined,
    });
  });

  it("delivers an OAuth error param", async () => {
    server = new McpLoopbackServer();
    const port = await server.start();
    const waiting = server.waitForCallback(5000);
    await fetch(`http://127.0.0.1:${port}/callback?error=access_denied`);
    const result = await waiting;
    expect(result.error).toBe("access_denied");
    expect(result.code).toBeUndefined();
  });

  it("is one-shot: a second redirect is answered but does not overwrite the first", async () => {
    server = new McpLoopbackServer();
    const port = await server.start();
    const waiting = server.waitForCallback(5000);
    await fetch(`http://127.0.0.1:${port}/callback?code=first&state=s1`);
    expect(await waiting).toMatchObject({ code: "first" });

    // A stray second redirect still gets the page, but doesn't buffer a result
    // that a later wait could pick up (that wait times out instead).
    const res = await fetch(`http://127.0.0.1:${port}/callback?code=second&state=s2`);
    expect(res.status).toBe(200);
    expect(await server.waitForCallback(150)).toEqual({
      error: "timed out waiting for the authorization redirect",
    });
  });

  it("ignores stray requests with no code/error (404, no resolve)", async () => {
    server = new McpLoopbackServer();
    const port = await server.start();
    const res = await fetch(`http://127.0.0.1:${port}/favicon.ico`);
    expect(res.status).toBe(404);
    // The wait still times out rather than resolving on the stray request.
    expect(await server.waitForCallback(150)).toEqual({
      error: "timed out waiting for the authorization redirect",
    });
  });
});
