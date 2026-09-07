import CryptoKit
import Foundation

// MARK: - Stored auth

/// OAuth tokens for one MCP server.
nonisolated struct MCPOAuthTokens: Codable, Hashable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var tokenType: String?
    var expiresAt: Date?

    /// True when the token is absent or within 60s of expiry.
    var isExpired: Bool {
        guard let expiresAt else { return false } // no expiry advertised → assume valid
        return expiresAt.timeIntervalSinceNow < 60
    }
}

/// Persisted OAuth state for one server: the discovered endpoints, the dynamically
/// registered client, and the current tokens.
nonisolated struct MCPServerAuth: Codable, Hashable, Sendable {
    var authorizationEndpoint: String?
    var tokenEndpoint: String?
    var registrationEndpoint: String?
    var clientID: String?
    var clientSecret: String?
    var scope: String?
    var resource: String?
    var tokens: MCPOAuthTokens?
    /// Fixed OAuth redirect URI for servers whose pre-registered client requires an exact
    /// redirect; nil uses the default random-port loopback.
    var redirectURI: String?
}

/// File shape for `~/.pi/agent/mcp-auth.json`.
private nonisolated struct MCPAuthFile: Codable {
    var servers: [String: MCPServerAuth]?
}

/// Persists per-server OAuth state next to `mcp.json`. Actor so reads/writes are safe
/// across the connection manager and the Connect UI.
actor MCPAuthStore {
    static let shared = MCPAuthStore()

    private let url: URL
    private var cache: [String: MCPServerAuth]?

    init(url: URL = MCPAuthStore.defaultURL()) {
        self.url = url
    }

    static func defaultURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent(".pi/agent/mcp-auth.json")
    }

    private func load() -> [String: MCPServerAuth] {
        if let cache { return cache }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(MCPAuthFile.self, from: $0) }?.servers ?? [:]
        cache = loaded
        return loaded
    }

    func auth(for server: String) -> MCPServerAuth? {
        load()[server]
    }

    func setAuth(_ auth: MCPServerAuth?, for server: String) {
        var servers = load()
        if let auth { servers[server] = auth } else { servers[server] = nil }
        cache = servers
        persist(servers)
    }

    /// A usable access token for `server`, or nil when none / expired (caller refreshes).
    func validAccessToken(for server: String) -> String? {
        guard let tokens = load()[server]?.tokens, !tokens.isExpired else { return nil }
        return tokens.accessToken
    }

    func isConnected(_ server: String) -> Bool {
        load()[server]?.tokens != nil
    }

    private func persist(_ servers: [String: MCPServerAuth]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(MCPAuthFile(servers: servers)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // OAuth tokens are sensitive: write 0600.
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - PKCE

/// RFC 7636 PKCE pair. `verifier` is kept secret; `challenge` goes in the auth URL.
nonisolated struct MCPPKCE: Sendable {
    let verifier: String
    let challenge: String
    let method = "S256"

    init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        verifier = Data(bytes).base64URLEncodedString()
        let digest = SHA256.hash(data: Data(verifier.utf8))
        challenge = Data(digest).base64URLEncodedString()
    }
}

extension Data {
    /// Base64URL without padding (RFC 4648 §5).
    nonisolated func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Discovery + token wire types

nonisolated struct MCPProtectedResourceMetadata: Decodable, Sendable {
    var authorization_servers: [String]?
    var resource: String?
}

nonisolated struct MCPAuthServerMetadata: Decodable, Sendable {
    var authorization_endpoint: String?
    var token_endpoint: String?
    var registration_endpoint: String?
    var scopes_supported: [String]?
}

nonisolated struct MCPTokenResponse: Decodable, Sendable {
    var access_token: String
    var refresh_token: String?
    var token_type: String?
    var expires_in: Double?
    var scope: String?

    func tokens(now: Date) -> MCPOAuthTokens {
        MCPOAuthTokens(
            accessToken: access_token,
            refreshToken: refresh_token,
            tokenType: token_type,
            expiresAt: expires_in.map { now.addingTimeInterval($0) }
        )
    }
}

nonisolated struct MCPClientRegistrationResponse: Decodable, Sendable {
    var client_id: String
    var client_secret: String?
}
