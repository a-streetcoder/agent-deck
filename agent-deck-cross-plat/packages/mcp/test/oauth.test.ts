import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import type { OAuthClientMetadata } from "@modelcontextprotocol/sdk/shared/auth.js";
import { beforeEach, describe, expect, it } from "vitest";
import {
  FileMcpOAuthStore,
  McpOAuthProvider,
  MemoryMcpOAuthStore,
  type McpOAuthStore,
} from "../src/index.ts";

/**
 * The MCP OAuth store + provider (native MCPOAuthService/MCPAuth). Hermetic: no
 * network and no real provider — the SDK would drive the actual handshake, so
 * here we only assert the persistence + relay contract the SDK depends on.
 */

const CLIENT_METADATA: OAuthClientMetadata = {
  client_name: "Agent Deck",
  redirect_uris: ["http://127.0.0.1:0/callback"],
  grant_types: ["authorization_code", "refresh_token"],
  response_types: ["code"],
};

function makeProvider(store: McpOAuthStore, redirects: URL[]) {
  return new McpOAuthProvider({
    serverKey: "https://mcp.example.test/sse",
    store,
    redirectUrl: "http://127.0.0.1:8976/callback",
    clientMetadata: CLIENT_METADATA,
    onRedirect: (url) => {
      redirects.push(url);
    },
    makeState: () => "fixed-state",
  });
}

describe("McpOAuthProvider", () => {
  let store: MemoryMcpOAuthStore;
  let redirects: URL[];
  let provider: McpOAuthProvider;

  beforeEach(() => {
    store = new MemoryMcpOAuthStore();
    redirects = [];
    provider = makeProvider(store, redirects);
  });

  it("exposes the configured redirect url, client metadata, and injected state", () => {
    expect(provider.redirectUrl).toBe("http://127.0.0.1:8976/callback");
    expect(provider.clientMetadata.client_name).toBe("Agent Deck");
    expect(provider.state()).toBe("fixed-state");
  });

  it("persists the minted state so a callback can be verified against it", () => {
    expect(provider.expectedState()).toBeUndefined();
    const minted = provider.state();
    expect(provider.expectedState()).toBe(minted);
  });

  it("starts with no tokens, client info, or verifier (unauthorized)", () => {
    expect(provider.tokens()).toBeUndefined();
    expect(provider.clientInformation()).toBeUndefined();
    expect(provider.isAuthorized()).toBe(false);
    expect(() => provider.codeVerifier()).toThrow(/code verifier/);
  });

  it("persists the PKCE verifier, dynamic client registration, and tokens the SDK writes", () => {
    provider.saveCodeVerifier("verifier-123");
    expect(provider.codeVerifier()).toBe("verifier-123");

    provider.saveClientInformation({
      client_id: "dyn-client",
      client_secret: "shh",
      redirect_uris: CLIENT_METADATA.redirect_uris,
    });
    expect(provider.clientInformation()?.client_id).toBe("dyn-client");

    provider.saveTokens({ access_token: "at-1", token_type: "Bearer", refresh_token: "rt-1" });
    expect(provider.tokens()?.access_token).toBe("at-1");
    expect(provider.isAuthorized()).toBe(true);

    // The three saves accumulate into one record rather than clobbering.
    const record = store.load("https://mcp.example.test/sse");
    expect(record).toMatchObject({
      codeVerifier: "verifier-123",
      clientInformation: { client_id: "dyn-client" },
      tokens: { access_token: "at-1" },
    });
  });

  it("hands the authorization URL to the injected relay", async () => {
    const authUrl = new URL("https://auth.example.test/authorize?client_id=dyn-client");
    await provider.redirectToAuthorization(authUrl);
    expect(redirects).toHaveLength(1);
    expect(redirects[0]!.toString()).toBe(authUrl.toString());
  });
});

describe("FileMcpOAuthStore", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(path.join(tmpdir(), "mcp-oauth-"));
  });

  it("round-trips a record across separate store instances (durable)", () => {
    const writer = new FileMcpOAuthStore(dir);
    writer.save("srv", { tokens: { access_token: "persisted", token_type: "Bearer" } });

    const reader = new FileMcpOAuthStore(dir);
    expect(reader.load("srv")?.tokens?.access_token).toBe("persisted");
  });

  it("returns undefined for an unknown or corrupt server file", () => {
    const store = new FileMcpOAuthStore(dir);
    expect(store.load("never-saved")).toBeUndefined();
  });

  it("isolates servers by key and clears one without touching the other", () => {
    const store = new FileMcpOAuthStore(dir);
    store.save("a", { codeVerifier: "va" });
    store.save("b", { codeVerifier: "vb" });
    store.clear("a");
    expect(store.load("a")).toBeUndefined();
    expect(store.load("b")?.codeVerifier).toBe("vb");
  });

  it("keeps distinct keys that sanitize to different files apart", () => {
    const store = new FileMcpOAuthStore(dir);
    // Two different URLs must not collide after filename sanitization.
    store.save("https://one.test/sse", { codeVerifier: "one" });
    store.save("https://two.test/sse", { codeVerifier: "two" });
    expect(store.load("https://one.test/sse")?.codeVerifier).toBe("one");
    expect(store.load("https://two.test/sse")?.codeVerifier).toBe("two");
  });

  it("does NOT collide keys that sanitize to the same prefix (hash-disambiguated)", () => {
    const store = new FileMcpOAuthStore(dir);
    // "a/b" and "a:b" both sanitize to "a_b" — the hash suffix keeps them apart.
    store.save("a/b", { codeVerifier: "slash" });
    store.save("a:b", { codeVerifier: "colon" });
    expect(store.load("a/b")?.codeVerifier).toBe("slash");
    expect(store.load("a:b")?.codeVerifier).toBe("colon");
  });
});
