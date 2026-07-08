import {
  McpOAuthProvider,
  runMcpAuth,
  type McpOAuthStore,
  type OAuthClientMetadata,
} from "@agent-deck/mcp";

/**
 * Coordinates the interactive OAuth handshake for authed HTTP MCP servers
 * (native MCPOAuthService). pi has no MCP — Agent Deck is the MCP client — so the
 * flow is ours: the SDK's `auth()` drives discovery + dynamic client
 * registration + PKCE + token exchange against an McpOAuthProvider (which
 * persists everything through an McpOAuthStore). `auth()` without a code REDIRECTs
 * (our provider surfaces the authorization URL through this coordinator's relay);
 * `auth()` with the browser's code completes the exchange and saves the tokens.
 * `auth()` is injected so the whole relay is hermetically testable without a real
 * provider; McpManager then connects with the now-authorized provider.
 */

/** The SDK `auth()` surface this coordinator drives (injected for tests). */
export type McpAuthFn = (
  provider: McpOAuthProvider,
  args: { serverUrl: string | URL; authorizationCode?: string },
) => Promise<"AUTHORIZED" | "REDIRECT">;

export interface McpAuthState {
  /** unauthenticated → no tokens; authorizing → URL issued, awaiting the code;
   *  authorized → tokens stored; error → the last attempt failed. */
  status: "unauthenticated" | "authorizing" | "authorized" | "error";
  /** The authorization URL to open, present while `authorizing`. */
  authUrl?: string;
  error?: string;
}

interface ServerAuth {
  provider: McpOAuthProvider;
  state: McpAuthState;
}

export class McpOAuthCoordinator {
  private readonly servers = new Map<string, ServerAuth>();
  private readonly authFn: McpAuthFn;
  private readonly store: McpOAuthStore;
  private readonly redirectUrl: string;

  constructor(options: { store: McpOAuthStore; redirectUrl: string; authFn?: McpAuthFn }) {
    this.store = options.store;
    this.redirectUrl = options.redirectUrl;
    this.authFn = options.authFn ?? (runMcpAuth as unknown as McpAuthFn);
  }

  private clientMetadata(): OAuthClientMetadata {
    return {
      client_name: "Agent Deck",
      redirect_uris: [this.redirectUrl],
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      token_endpoint_auth_method: "none",
    };
  }

  /** The provider for a server, created (and cached) on first use. */
  providerFor(serverId: string): McpOAuthProvider {
    const existing = this.servers.get(serverId);
    if (existing) return existing.provider;
    const provider = new McpOAuthProvider({
      serverKey: serverId,
      store: this.store,
      redirectUrl: this.redirectUrl,
      clientMetadata: this.clientMetadata(),
      onRedirect: (url) => {
        // The SDK calls this mid-`auth()` with the URL to open; park it on state.
        const entry = this.servers.get(serverId);
        if (entry) {
          entry.state = { status: "authorizing", authUrl: url.toString() };
        }
      },
    });
    this.servers.set(serverId, {
      provider,
      state: { status: provider.isAuthorized() ? "authorized" : "unauthenticated" },
    });
    return provider;
  }

  /** Current auth state for a server (defaults to unauthenticated). */
  state(serverId: string): McpAuthState {
    return this.servers.get(serverId)?.state ?? { status: "unauthenticated" };
  }

  isAuthorized(serverId: string): boolean {
    return this.providerFor(serverId).isAuthorized();
  }

  /**
   * Begin authorization: `auth()` with no code discovers/registers and either
   * finds valid tokens (AUTHORIZED) or issues an authorization URL (REDIRECT,
   * surfaced on the state via onRedirect). Returns the resulting state.
   */
  async beginAuth(serverId: string, serverUrl: string | URL): Promise<McpAuthState> {
    const provider = this.providerFor(serverId);
    try {
      const result = await this.authFn(provider, { serverUrl });
      const entry = this.servers.get(serverId)!;
      if (result === "AUTHORIZED") {
        entry.state = { status: "authorized" };
      } else if (entry.state.status !== "authorizing") {
        // REDIRECT is expected to have set `authorizing` via onRedirect; if it
        // didn't, record a clear error rather than a silent no-op.
        entry.state = { status: "error", error: "authorization did not produce a URL" };
      }
      return entry.state;
    } catch (error) {
      return this.fail(serverId, error);
    }
  }

  /**
   * Complete authorization with the code from the browser redirect: `auth()`
   * exchanges it for tokens (persisted via the provider). Returns the new state.
   */
  async submitCode(serverId: string, serverUrl: string | URL, code: string): Promise<McpAuthState> {
    const provider = this.providerFor(serverId);
    try {
      const result = await this.authFn(provider, { serverUrl, authorizationCode: code });
      const entry = this.servers.get(serverId)!;
      entry.state =
        result === "AUTHORIZED" || provider.isAuthorized()
          ? { status: "authorized" }
          : { status: "error", error: "code exchange did not authorize" };
      return entry.state;
    } catch (error) {
      return this.fail(serverId, error);
    }
  }

  /**
   * Verify a callback's `state` against the one the provider minted (CSRF). The
   * provider persists only the MOST RECENT minted state, so a fresh beginAuth
   * supersedes any earlier in-flight attempt (last-sign-in-wins — the expected
   * shape for a single user driving one browser flow). A forged/stale state is
   * always rejected; only the exact last-minted value passes.
   */
  verifyState(serverId: string, callbackState: string | undefined): boolean {
    const expected = this.providerFor(serverId).expectedState();
    return Boolean(expected) && expected === callbackState;
  }

  /** Forget a server's auth tokens + in-memory state (logout / config removal). */
  clear(serverId: string): void {
    this.store.clear(serverId);
    this.servers.delete(serverId);
  }

  private fail(serverId: string, error: unknown): McpAuthState {
    const entry = this.servers.get(serverId);
    const state: McpAuthState = {
      status: "error",
      error: error instanceof Error ? error.message : String(error),
    };
    if (entry) entry.state = state;
    return state;
  }
}
