import Foundation

/// One live connection to a single MCP server. Owns the JSON-RPC request/response
/// matching, the initialize handshake, tool discovery (with cursor pagination), and
/// tool invocation. Lazy by default: it connects on first use.
actor MCPConnection {
    /// Builds a transport for a server config. Injectable so tests can swap in a stub.
    typealias TransportFactory = @Sendable (MCPServerConfig) throws -> MCPTransport

    /// Default factory: stdio for local servers, streamable-HTTP for remote (http/sse).
    nonisolated static let defaultTransportFactory: TransportFactory = { config in
        switch config.resolvedTransport {
        case .stdio: return MCPStdioTransport(config: config)
        case .http, .sse: return try MCPHTTPTransport(config: config)
        }
    }

    let name: String
    private let config: MCPServerConfig
    private let transportFactory: TransportFactory
    private let clientName: String
    private let clientVersion: String
    private let requestTimeout: Duration

    private var transport: MCPTransport?
    private var connectTask: Task<Void, Error>?
    private var isConnected = false

    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONRPCResponse, Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]

    init(name: String,
         config: MCPServerConfig,
         clientName: String = "Agent Deck",
         clientVersion: String = "1.0",
         requestTimeout: Duration = .seconds(30),
         transportFactory: @escaping TransportFactory = MCPConnection.defaultTransportFactory) {
        self.name = name
        self.config = config
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.requestTimeout = requestTimeout
        self.transportFactory = transportFactory
    }

    // MARK: - Lifecycle

    func ensureConnected() async throws {
        if isConnected { return }
        if let connectTask { try await connectTask.value; return }
        let task = Task { try await self.performConnect() }
        connectTask = task
        do {
            try await task.value
        } catch {
            connectTask = nil
            throw error
        }
        connectTask = nil
    }

    private func performConnect() async throws {
        let transport = try transportFactory(config)
        try await transport.start(
            onLine: { [weak self] line in Task { await self?.ingest(line) } },
            onClose: { [weak self] error in Task { await self?.handleClose(error) } }
        )
        self.transport = transport
        // Handshake: initialize (await result), then the initialized notification.
        _ = try await request(method: MCPMethod.initialize,
                              params: MCPRequestFactory.initialize(id: 0, clientName: clientName, clientVersion: clientVersion).params)
        try await sendNotification(MCPRequestFactory.initialized())
        isConnected = true
    }

    func close() async {
        connectTask?.cancel()
        connectTask = nil
        isConnected = false
        let transport = self.transport
        self.transport = nil
        failAllPending(MCPError.cancelled)
        await transport?.close()
    }

    private func handleClose(_ error: MCPError?) {
        isConnected = false
        transport = nil
        failAllPending(error ?? MCPError.transportFailed("connection closed"))
    }

    // MARK: - Operations

    func listTools() async throws -> [MCPToolDescriptor] {
        try await ensureConnected()
        var tools: [MCPToolDescriptor] = []
        var cursor: String?
        repeat {
            let response = try await request(
                method: MCPMethod.toolsList,
                params: MCPRequestFactory.toolsList(id: 0, cursor: cursor).params
            )
            let result = try decodeResult(response, as: MCPToolsListResult.self)
            tools.append(contentsOf: result.tools)
            cursor = result.nextCursor
        } while cursor != nil
        return tools
    }

    func callTool(name toolName: String, arguments: JSONValue?) async throws -> MCPCallResult {
        let normalizedArguments = try MCPRequestFactory.normalizedToolArguments(arguments)
        try await ensureConnected()
        let response = try await request(
            method: MCPMethod.toolsCall,
            params: MCPRequestFactory.toolsCall(id: 0, name: toolName, arguments: normalizedArguments).params
        )
        return try decodeResult(response, as: MCPCallResult.self)
    }

    // MARK: - JSON-RPC plumbing

    private func request(method: String, params: JSONValue?) async throws -> JSONRPCResponse {
        let id = nextID
        nextID += 1
        let line = try MCPRequestFactory.encodeLine(JSONRPCRequest(id: id, method: method, params: params))
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeoutTasks[id] = Task { [weak self, requestTimeout] in
                try? await Task.sleep(for: requestTimeout)
                await self?.failPending(id: id, error: MCPError.timeout(method))
            }
            Task { [weak self] in
                do {
                    guard let transport = await self?.transport else {
                        await self?.failPending(id: id, error: MCPError.transportFailed("transport not started"))
                        return
                    }
                    try await transport.send(line)
                } catch let mcp as MCPError {
                    await self?.failPending(id: id, error: mcp) // preserve .unauthorized etc.
                } catch {
                    await self?.failPending(id: id, error: MCPError.transportFailed(error.localizedDescription))
                }
            }
        }
    }

    private func sendNotification(_ request: JSONRPCRequest) async throws {
        guard let transport else { throw MCPError.transportFailed("transport not started") }
        let line = try MCPRequestFactory.encodeLine(request)
        try await transport.send(line)
    }

    private func ingest(_ line: String) {
        guard let response = try? MCPRequestFactory.decode(line) else { return }
        if response.isNotification { return } // v1 ignores server notifications
        guard case let .int(id)? = response.id else { return }
        timeoutTasks.removeValue(forKey: id)?.cancel()
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(returning: response)
    }

    private func failPending(id: Int, error: Error) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failAllPending(_ error: Error) {
        for task in timeoutTasks.values { task.cancel() }
        timeoutTasks.removeAll()
        let continuations = pending
        pending.removeAll()
        for continuation in continuations.values { continuation.resume(throwing: error) }
    }

    private func decodeResult<T: Decodable>(_ response: JSONRPCResponse, as type: T.Type) throws -> T {
        if let error = response.error {
            throw MCPError.rpc(code: error.code, message: error.message)
        }
        guard let result = response.result else {
            throw MCPError.decoding("missing result for \(T.self)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(result))
        } catch {
            throw MCPError.decoding(error.localizedDescription)
        }
    }
}
