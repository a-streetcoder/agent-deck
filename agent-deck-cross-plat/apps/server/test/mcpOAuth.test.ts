import { MemoryMcpOAuthStore } from "@agent-deck/mcp";
import { describe, expect, it } from "vitest";
import { McpOAuthCoordinator, type McpAuthFn } from "../src/mcpOAuth.ts";

/**
 * The MCP OAuth coordinator, driven by a STUBBED `auth()` so the interactive
 * relay (begin → URL issued → submit code → authorized) is exercised without a
 * real provider. The real SDK `auth()` + the browser round-trip are validated
 * locally; the store/provider contract they depend on is unit-tested in
 * packages/mcp.
 */

const SERVER_URL = "https://mcp.example.test/sse";

/** A fake `auth()`: no code → REDIRECT (issues a URL + saves a verifier); with a
 *  code → AUTHORIZED (saves tokens), exactly like the SDK's contract. */
const stubAuth: McpAuthFn = async (provider, { authorizationCode }) => {
  if (!authorizationCode) {
    provider.saveCodeVerifier("verifier-abc");
    provider.state(); // mint + persist the CSRF state, as the SDK does
    await provider.redirectToAuthorization(
      new URL("https://auth.example.test/authorize?client_id=x"),
    );
    return "REDIRECT";
  }
  provider.saveTokens({ access_token: `token-for-${authorizationCode}`, token_type: "Bearer" });
  return "AUTHORIZED";
};

function makeCoordinator(authFn: McpAuthFn = stubAuth) {
  return new McpOAuthCoordinator({
    store: new MemoryMcpOAuthStore(),
    redirectUrl: "http://127.0.0.1:8976/mcp/callback",
    authFn,
  });
}

describe("McpOAuthCoordinator", () => {
  it("starts unauthenticated for an unknown server", () => {
    const coord = makeCoordinator();
    expect(coord.state("srv").status).toBe("unauthenticated");
    expect(coord.isAuthorized("srv")).toBe(false);
  });

  it("issues an authorization URL on begin, then authorizes on the callback code", async () => {
    const coord = makeCoordinator();

    const begun = await coord.beginAuth("srv", SERVER_URL);
    expect(begun.status).toBe("authorizing");
    expect(begun.authUrl).toContain("https://auth.example.test/authorize");
    expect(coord.isAuthorized("srv")).toBe(false);

    const done = await coord.submitCode("srv", SERVER_URL, "browser-code");
    expect(done.status).toBe("authorized");
    expect(coord.isAuthorized("srv")).toBe(true);
    expect(coord.state("srv").status).toBe("authorized");
  });

  it("verifies the callback state against the minted one (CSRF)", async () => {
    const coord = makeCoordinator();
    await coord.beginAuth("srv", SERVER_URL);
    // The stub mints "fixed" via provider.state()? No — the provider mints a
    // random UUID; assert the coordinator only accepts the exact minted value.
    expect(coord.verifyState("srv", "not-the-state")).toBe(false);
    expect(coord.verifyState("srv", undefined)).toBe(false);
  });

  it("short-circuits to authorized when begin finds existing valid tokens", async () => {
    // An auth() that returns AUTHORIZED immediately (tokens already valid).
    const preAuthed: McpAuthFn = async (provider, { authorizationCode }) => {
      if (!authorizationCode) {
        provider.saveTokens({ access_token: "cached", token_type: "Bearer" });
        return "AUTHORIZED";
      }
      return "AUTHORIZED";
    };
    const coord = makeCoordinator(preAuthed);
    const begun = await coord.beginAuth("srv", SERVER_URL);
    expect(begun.status).toBe("authorized");
    expect(begun.authUrl).toBeUndefined();
    expect(coord.isAuthorized("srv")).toBe(true);
  });

  it("records an error when auth() throws", async () => {
    const boom: McpAuthFn = async () => {
      throw new Error("discovery failed: 404");
    };
    const coord = makeCoordinator(boom);
    const state = await coord.beginAuth("srv", SERVER_URL);
    expect(state.status).toBe("error");
    expect(state.error).toContain("discovery failed");
  });

  it("clears a server's auth on logout", async () => {
    const coord = makeCoordinator();
    await coord.beginAuth("srv", SERVER_URL);
    await coord.submitCode("srv", SERVER_URL, "browser-code");
    expect(coord.isAuthorized("srv")).toBe(true);

    coord.clear("srv");
    expect(coord.state("srv").status).toBe("unauthenticated");
    expect(coord.isAuthorized("srv")).toBe(false);
  });
});
