import Foundation

/// One tool surfaced by a probe (name + description), for the detail tool list.
nonisolated struct MCPProbeTool: Sendable, Hashable, Identifiable {
    let name: String
    let description: String?
    var id: String { name }
}

/// Outcome of a one-shot server probe (the management UI's connection test).
nonisolated enum MCPProbeResult: Sendable, Equatable {
    case ok([MCPProbeTool])
    case failure(String)

    var toolCount: Int { if case let .ok(tools) = self { return tools.count }; return 0 }
}

/// One discoverable MCP tool, addressed as `server/tool`.
nonisolated struct MCPCatalogEntry: Hashable, Sendable, Identifiable {
    var server: String
    var tool: String
    var description: String?
    var id: String { "\(server)/\(tool)" }
    var qualifiedName: String { "\(server)/\(tool)" }
}

/// App-shared owner of every MCP server connection. Built from merged `mcp.json`
/// config; connections are lazy unless their lifecycle is `eager`. Survives across
/// sessions; `shutdown()` tears everything down at app quit.
actor MCPConnectionManager {
    private let clientName: String
    private let clientVersion: String
    private let requestTimeout: Duration
    private let transportFactory: MCPConnection.TransportFactory

    private var configs: [String: MCPServerConfig] = [:]
    private var policies: [String: MCPServerToolPolicy] = [:]
    /// Incremented before any awaited close. Older configure calls re-check this
    /// epoch before they mutate state, so actor reentrancy cannot restore stale config.
    private var configurationEpoch: UInt64 = 0
    private var connections: [String: MCPConnection] = [:]
    /// Tool descriptors discovered per server, cached for describe/search and the catalog.
    private var toolCache: [String: [MCPToolDescriptor]] = [:]
    /// Resolves an OAuth access token for a server name (set by AppViewModel). Used to
    /// authorize remote (http) transports.
    private var authTokenProvider: (@Sendable (String) async -> String?)?
    /// Installed by a future approval surface. Absence intentionally declines elicitation.
    private var serverRequestHandler: MCPServerRequestHandler?

    func setServerRequestHandler(_ handler: MCPServerRequestHandler?) {
        serverRequestHandler = handler
    }

    func setAuthTokenProvider(_ provider: @escaping @Sendable (String) async -> String?) {
        authTokenProvider = provider
    }

    init(clientName: String = "Agent Deck",
         clientVersion: String = "1.0",
         requestTimeout: Duration = .seconds(30),
         transportFactory: @escaping MCPConnection.TransportFactory = MCPConnection.defaultTransportFactory) {
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.requestTimeout = requestTimeout
        self.transportFactory = transportFactory
    }

    /// Rebuilds the connection set from config. Unchanged servers keep their live
    /// connection; changed/removed ones are closed.
    func configure(servers: [MCPServerEntry],
                   refreshToken: UInt64? = nil,
                   refreshCoordinator: MCPConfigurationRefreshCoordinator? = nil) async {
        let refreshIsCurrent = { refreshToken == nil || refreshCoordinator?.isCurrent(refreshToken!) == true }
        // Do not let a stale request advance the local epoch: a current configure may
        // be suspended in close() and must still be allowed to publish when it resumes.
        guard refreshIsCurrent() else { return }
        configurationEpoch &+= 1
        let epoch = configurationEpoch
        var newConfigs: [String: MCPServerConfig] = [:]
        var newPolicies: [String: MCPServerToolPolicy] = [:]
        for entry in servers where entry.isAvailable {
            newConfigs[entry.name] = entry.config
            newPolicies[entry.name] = entry.toolPolicy
        }

        // Close connections that were removed or whose config changed.
        for (name, connection) in connections where newConfigs[name] != configs[name] {
            await connection.close()
            // A newer configure may have run while close() suspended this actor.
            // Do not clear its live connection or publish this older config.
            guard epoch == configurationEpoch, refreshIsCurrent() else { return }
            connections[name] = nil
            toolCache[name] = nil
        }
        guard epoch == configurationEpoch, refreshIsCurrent() else { return }
        configs = newConfigs
        policies = newPolicies
        // Drop connections for servers no longer present.
        for name in connections.keys where newConfigs[name] == nil {
            connections[name] = nil
            toolCache[name] = nil
        }
    }

    /// Eagerly connects servers marked `lifecycle: eager` so their tools populate the
    /// catalog up front. Lazy servers connect on first use.
    func connectEagerServers() async {
        for (name, config) in configs where config.resolvedLifecycle == .eager {
            _ = try? await listTools(server: name)
        }
    }

    private func connection(for name: String) throws -> MCPConnection {
        if let existing = connections[name] { return existing }
        guard let config = configs[name] else { throw MCPError.serverNotConfigured(name) }
        // Per-server factory: stdio goes through the injected factory (stub in tests);
        // remote (http/sse) gets an OAuth-token-aware transport bound to this server.
        let injected = transportFactory
        let provider = authTokenProvider
        let factory: MCPConnection.TransportFactory = { serverConfig in
            switch serverConfig.resolvedTransport {
            case .stdio:
                return try injected(serverConfig)
            case .http, .sse:
                let tokenProvider: (@Sendable () async -> String?)? = provider.map { resolve in
                    let bound: @Sendable () async -> String? = { await resolve(name) }
                    return bound
                }
                return try MCPHTTPTransport(config: serverConfig, tokenProvider: tokenProvider)
            }
        }
        let connection = MCPConnection(
            name: name,
            config: config,
            clientName: clientName,
            clientVersion: clientVersion,
            requestTimeout: policies[name] == .computerUseObservationOnly ? .seconds(5) : requestTimeout,
            serverRequestHandler: config.resolvedTransport == .stdio ? serverRequestHandler : nil,
            transportFactory: factory
        )
        connections[name] = connection
        return connection
    }

    @discardableResult
    private func listTools(server: String) async throws -> [MCPToolDescriptor] {
        let tools = try await connection(for: server).listTools()
        let permitted = tools.filter { policies[server, default: .unrestricted].allows($0.name) }
        toolCache[server] = permitted
        return permitted
    }

    /// Connects each in-scope server and returns its tools as catalog entries. Servers
    /// that fail to connect are skipped (their error is swallowed here; surfaced on call).
    func discoverCatalog(serverNames: Set<String>) async -> [MCPCatalogEntry] {
        var entries: [MCPCatalogEntry] = []
        for name in configs.keys.sorted() where serverNames.contains(name) {
            guard let tools = try? await listTools(server: name) else { continue }
            for tool in tools {
                entries.append(MCPCatalogEntry(server: name, tool: tool.name, description: tool.description))
            }
        }
        return entries
    }

    func call(server: String, tool: String, arguments: JSONValue?, context: MCPCallContext) async throws -> MCPCallResult {
        guard policies[server, default: .unrestricted].allows(tool) else {
            throw MCPError.policyDenied("Codex Computer Use is observation-only in Agent Deck; only list_apps is allowed.")
        }
        let result = try await connection(for: server).callTool(name: tool, arguments: arguments, context: context)
        if policies[server] == .computerUseObservationOnly,
           result.isError == true,
           result.combinedText.contains("-1743") {
            throw MCPError.runtimeAuthorization("Codex Computer Use needs macOS Automation authorization (error -1743). Allow it in System Settings before retrying list_apps.")
        }
        return result
    }

    /// Returns a cached descriptor for `server/tool`, discovering the server's tools
    /// first if they aren't cached yet.
    func describe(server: String, tool: String) async -> MCPToolDescriptor? {
        if toolCache[server] == nil { _ = try? await listTools(server: server) }
        return toolCache[server]?.first { $0.name == tool }
    }

    /// Case-insensitive substring search over cached in-scope tools (name + description).
    func search(query: String, serverNames: Set<String>) -> [MCPCatalogEntry] {
        let needle = query.lowercased()
        var entries: [MCPCatalogEntry] = []
        for (server, tools) in toolCache where serverNames.contains(server) {
            for tool in tools where needle.isEmpty
                || tool.name.lowercased().contains(needle)
                || (tool.description?.lowercased().contains(needle) ?? false) {
                entries.append(MCPCatalogEntry(server: server, tool: tool.name, description: tool.description))
            }
        }
        return entries.sorted { $0.qualifiedName < $1.qualifiedName }
    }

    /// Tools already discovered for a server (catalog warm-up or a prior list), without
    /// opening a connection. nil when nothing has been discovered yet.
    func cachedTools(server: String) -> [MCPToolDescriptor]? { toolCache[server] }

    /// Whether a live connection to this server already exists (reused across sessions).
    func hasLiveConnection(_ server: String) -> Bool { connections[server] != nil }

    /// Current resolved config, primarily useful for diagnostics and concurrency tests.
    func configuredConfig(server: String) -> MCPServerConfig? { configs[server] }

    /// Connect + list against a config entry, for a "test connection" button. Reuses the
    /// live connection when one already exists, so re-testing an already-connected server
    /// doesn't spawn a second process or re-trigger its permission prompt. Only servers
    /// with no live connection get a throwaway probe (so it still works for read-only
    /// servers not in the live set).
    func probe(entry: MCPServerEntry) async -> MCPProbeResult {
        if connections[entry.name] != nil {
            do {
                let tools = try await listTools(server: entry.name)
                return .ok(tools.map { MCPProbeTool(name: $0.name, description: $0.description) })
            } catch {
                return .failure((error as? MCPError)?.errorDescription ?? error.localizedDescription)
            }
        }
        let injected = transportFactory
        let provider = authTokenProvider
        let serverName = entry.name
        let factory: MCPConnection.TransportFactory = { serverConfig in
            switch serverConfig.resolvedTransport {
            case .stdio:
                return try injected(serverConfig)
            case .http, .sse:
                let tokenProvider: (@Sendable () async -> String?)? = provider.map { resolve in
                    let bound: @Sendable () async -> String? = { await resolve(serverName) }
                    return bound
                }
                return try MCPHTTPTransport(config: serverConfig, tokenProvider: tokenProvider)
            }
        }
        let connection = MCPConnection(
            name: entry.name,
            config: entry.config,
            clientName: clientName,
            clientVersion: clientVersion,
            requestTimeout: entry.toolPolicy == .computerUseObservationOnly ? .seconds(5) : .seconds(20),
            serverRequestHandler: entry.config.resolvedTransport == .stdio ? serverRequestHandler : nil,
            transportFactory: factory
        )
        do {
            let tools = try await connection.listTools()
            await connection.close()
            return .ok(tools.map { MCPProbeTool(name: $0.name, description: $0.description) })
        } catch {
            await connection.close()
            return .failure((error as? MCPError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func shutdown() async {
        for connection in connections.values { await connection.close() }
        connections.removeAll()
        toolCache.removeAll()
    }

    /// Splits a `"server/tool"` address, falling back to `serverHint` when the string
    /// carries no slash. Returns nil when neither yields a server.
    nonisolated static func resolveAddress(_ raw: String, serverHint: String?) -> (server: String, tool: String)? {
        if let slash = raw.firstIndex(of: "/") {
            let server = String(raw[..<slash])
            let tool = String(raw[raw.index(after: slash)...])
            if !server.isEmpty, !tool.isEmpty { return (server, tool) }
        }
        if let serverHint, !serverHint.isEmpty, !raw.isEmpty { return (serverHint, raw) }
        return nil
    }
}
