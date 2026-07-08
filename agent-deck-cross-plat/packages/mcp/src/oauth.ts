import { createHash, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { auth } from "@modelcontextprotocol/sdk/client/auth.js";
import type { OAuthClientProvider } from "@modelcontextprotocol/sdk/client/auth.js";
import type {
  OAuthClientInformationFull,
  OAuthClientMetadata,
  OAuthTokens,
} from "@modelcontextprotocol/sdk/shared/auth.js";

// Re-export the SDK's OAuth driver + metadata type so consumers (apps/server)
// reach them through this package rather than depending on the SDK directly.
export { auth as runMcpAuth };
export type { OAuthClientMetadata, OAuthTokens };

/**
 * OAuth for authed HTTP MCP servers (native MCPOAuthService + MCPAuth). pi has
 * no MCP of its own — Agent Deck IS the MCP client and proxies each server's
 * tools into pi over the bridge — so the OAuth handshake is ours to own too. The
 * official @modelcontextprotocol/sdk ships the whole flow behind its
 * OAuthClientProvider interface (discovery, dynamic client registration, PKCE,
 * token exchange + refresh); this module is the durable, testable half of that:
 * a per-server token store and a provider that reads/writes it, with the
 * interactive redirect surfaced through an injected relay (the same shape as
 * provider-login's ProviderLoginManager). The real browser round-trip is wired
 * in a later slice; here everything is hermetic (injected onRedirect + state).
 */

/** Persisted OAuth state for ONE MCP server. */
export interface McpOAuthRecord {
  tokens?: OAuthTokens;
  clientInformation?: OAuthClientInformationFull;
  /** The in-flight PKCE verifier, kept between redirect and token exchange. */
  codeVerifier?: string;
  /** The most recently minted OAuth2 `state`, to verify against the callback. */
  state?: string;
}

/**
 * Durable per-server OAuth store (the auth.json analogue for MCP servers).
 * Implementations are SYNCHRONOUS by contract (the methods return plain values,
 * not promises): the provider's read-modify-write in `update()` therefore never
 * interleaves within a single-threaded process, so no locking is needed.
 */
export interface McpOAuthStore {
  load(serverKey: string): McpOAuthRecord | undefined;
  save(serverKey: string, record: McpOAuthRecord): void;
  clear(serverKey: string): void;
}

/** Ephemeral in-memory store (tests, and servers that don't need persistence). */
export class MemoryMcpOAuthStore implements McpOAuthStore {
  private readonly records = new Map<string, McpOAuthRecord>();

  load(serverKey: string): McpOAuthRecord | undefined {
    return this.records.get(serverKey);
  }

  save(serverKey: string, record: McpOAuthRecord): void {
    this.records.set(serverKey, record);
  }

  clear(serverKey: string): void {
    this.records.delete(serverKey);
  }
}

/**
 * A safe, COLLISION-FREE filename for a server key (a URL or name). Sanitizing
 * alone can map distinct keys onto the same name (`a/b` and `a:b` → `a_b`), which
 * would let one server read/overwrite another's tokens — so a hash of the exact
 * key is appended to guarantee uniqueness while the readable prefix aids
 * debugging. The prefix also can't traverse the dir (no `/` or `..` survive).
 */
function storeFileName(serverKey: string): string {
  const prefix = serverKey.replace(/[^a-zA-Z0-9._-]/g, "_").slice(0, 120) || "server";
  const digest = createHash("sha256").update(serverKey).digest("hex").slice(0, 16);
  return `${prefix}-${digest}.json`;
}

/**
 * File-backed store: one JSON file per server under `baseDir`. Tokens are a
 * credential, so the directory is created 0700 and files 0600.
 */
export class FileMcpOAuthStore implements McpOAuthStore {
  constructor(private readonly baseDir: string) {}

  private filePath(serverKey: string): string {
    return path.join(this.baseDir, storeFileName(serverKey));
  }

  load(serverKey: string): McpOAuthRecord | undefined {
    const file = this.filePath(serverKey);
    if (!existsSync(file)) return undefined;
    try {
      return JSON.parse(readFileSync(file, "utf8")) as McpOAuthRecord;
    } catch {
      // A corrupt/hand-edited file behaves as "not authed" rather than crashing.
      return undefined;
    }
  }

  save(serverKey: string, record: McpOAuthRecord): void {
    mkdirSync(this.baseDir, { recursive: true, mode: 0o700 });
    writeFileSync(this.filePath(serverKey), JSON.stringify(record, null, 2), { mode: 0o600 });
  }

  clear(serverKey: string): void {
    rmSync(this.filePath(serverKey), { force: true });
  }
}

export interface McpOAuthProviderOptions {
  /** Identifies the server in the store (the config name or URL). */
  serverKey: string;
  store: McpOAuthStore;
  /** Where the provider redirects back to after authorization (our callback). */
  redirectUrl: string | URL;
  clientMetadata: OAuthClientMetadata;
  /** Surface the authorization URL to the user (open a browser / show a link). */
  onRedirect: (url: URL) => void | Promise<void>;
  /** OAuth2 `state` factory; injectable so tests are deterministic. */
  makeState?: () => string;
}

/**
 * The SDK's OAuthClientProvider backed by an McpOAuthStore. The SDK drives the
 * protocol (auth()/finishAuth on the transport call these hooks); this only
 * persists state and hands the authorization URL to the relay.
 */
export class McpOAuthProvider implements OAuthClientProvider {
  private readonly serverKey: string;
  private readonly store: McpOAuthStore;
  private readonly _redirectUrl: string | URL;
  private readonly _clientMetadata: OAuthClientMetadata;
  private readonly onRedirect: (url: URL) => void | Promise<void>;
  private readonly makeState: () => string;

  constructor(options: McpOAuthProviderOptions) {
    this.serverKey = options.serverKey;
    this.store = options.store;
    this._redirectUrl = options.redirectUrl;
    this._clientMetadata = options.clientMetadata;
    this.onRedirect = options.onRedirect;
    this.makeState = options.makeState ?? (() => randomUUID());
  }

  private record(): McpOAuthRecord {
    return this.store.load(this.serverKey) ?? {};
  }

  private update(patch: Partial<McpOAuthRecord>): void {
    this.store.save(this.serverKey, { ...this.record(), ...patch });
  }

  get redirectUrl(): string | URL {
    return this._redirectUrl;
  }

  get clientMetadata(): OAuthClientMetadata {
    return this._clientMetadata;
  }

  state(): string {
    // Persist the minted state so the redirect handler can verify the callback's
    // `state` matches (CSRF protection alongside PKCE).
    const state = this.makeState();
    this.update({ state });
    return state;
  }

  /** The most recently minted state, for verifying an incoming callback. */
  expectedState(): string | undefined {
    return this.record().state;
  }

  clientInformation(): OAuthClientInformationFull | undefined {
    return this.record().clientInformation;
  }

  saveClientInformation(clientInformation: OAuthClientInformationFull): void {
    this.update({ clientInformation });
  }

  tokens(): OAuthTokens | undefined {
    return this.record().tokens;
  }

  saveTokens(tokens: OAuthTokens): void {
    this.update({ tokens });
  }

  redirectToAuthorization(authorizationUrl: URL): void | Promise<void> {
    return this.onRedirect(authorizationUrl);
  }

  saveCodeVerifier(codeVerifier: string): void {
    this.update({ codeVerifier });
  }

  codeVerifier(): string {
    const verifier = this.record().codeVerifier;
    if (!verifier)
      throw new Error(`No PKCE code verifier stored for MCP server "${this.serverKey}"`);
    return verifier;
  }

  /** Has this server completed authorization (has an access token)? */
  isAuthorized(): boolean {
    return typeof this.record().tokens?.access_token === "string";
  }
}
