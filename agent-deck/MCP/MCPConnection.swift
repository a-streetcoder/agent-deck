import Foundation

/// One live connection to a single MCP server. Server requests are discriminated
/// before response matching, so a server integer ID cannot collide with a client ID.
actor MCPConnection {
    typealias TransportFactory = @Sendable (MCPServerConfig) throws -> MCPTransport
    nonisolated static let defaultTransportFactory: TransportFactory = { config in
        switch config.resolvedTransport { case .stdio: return MCPStdioTransport(config: config); case .http, .sse: return try MCPHTTPTransport(config: config) }
    }

    let name: String
    private let config: MCPServerConfig; private let transportFactory: TransportFactory
    private let clientName: String; private let clientVersion: String; private let requestTimeout: Duration
    private let serverRequestHandler: MCPServerRequestHandler?
    private var transport: MCPTransport?; private var connectTask: Task<Void, Error>?; private var isConnected = false
    private var nextID = 1
    private var supportsDuplexServerRequests = false
    private var interactiveElicitationEnabled = false
    private var sentRequestIDs: Set<Int> = []
    private struct Pending { let continuation: CheckedContinuation<JSONRPCResponse, Error>; let method: String; let context: MCPCallContext? }
    private var pending: [Int: Pending] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]

    init(name: String, config: MCPServerConfig, clientName: String = "Agent Deck", clientVersion: String = "1.0", requestTimeout: Duration = .seconds(30), serverRequestHandler: MCPServerRequestHandler? = nil, transportFactory: @escaping TransportFactory = MCPConnection.defaultTransportFactory) {
        self.name = name; self.config = config; self.clientName = clientName; self.clientVersion = clientVersion; self.requestTimeout = requestTimeout; self.serverRequestHandler = serverRequestHandler; self.transportFactory = transportFactory
    }

    func ensureConnected() async throws {
        if isConnected { return }; if let connectTask { try await connectTask.value; return }
        let task = Task { try await self.performConnect() }; connectTask = task
        do { try await task.value } catch { connectTask = nil; throw error }; connectTask = nil
    }
    private func performConnect() async throws {
        let transport = try transportFactory(config)
        try await transport.start(onLine: { [weak self] line in Task { await self?.ingest(line) } }, onClose: { [weak self] error in Task { await self?.handleClose(error) } })
        self.transport = transport
        supportsDuplexServerRequests = transport.supportsDuplexServerRequests
        let offerElicitation = serverRequestHandler != nil && supportsDuplexServerRequests
        let initializeResponse = try await request(method: MCPMethod.initialize, params: MCPRequestFactory.initialize(id: 0, clientName: clientName, clientVersion: clientVersion, supportsElicitation: offerElicitation).params, context: nil)
        if let result = initializeResponse.result,
           let selected = try? JSONDecoder().decode(MCPInitializeResult.self, from: JSONEncoder().encode(result)) {
            interactiveElicitationEnabled = offerElicitation && MCPProtocolVersion.supportsElicitation(selected.protocolVersion)
        }
        try await sendNotification(MCPRequestFactory.initialized()); isConnected = true
    }
    func close() async { connectTask?.cancel(); connectTask = nil; isConnected = false; let transport = self.transport; self.transport = nil; failAllPending(MCPError.cancelled, reason: "connection closed"); await transport?.close() }
    private func handleClose(_ error: MCPError?) { isConnected = false; transport = nil; failAllPending(error ?? .transportFailed("connection closed"), reason: "connection closed") }

    func listTools() async throws -> [MCPToolDescriptor] {
        try await ensureConnected(); var tools: [MCPToolDescriptor] = []; var cursor: String?
        repeat { let response = try await request(method: MCPMethod.toolsList, params: MCPRequestFactory.toolsList(id: 0, cursor: cursor).params, context: nil); let result = try decodeResult(response, as: MCPToolsListResult.self); tools += result.tools; cursor = result.nextCursor } while cursor != nil
        return tools
    }
    func callTool(name toolName: String, arguments: JSONValue?, context: MCPCallContext? = nil) async throws -> MCPCallResult {
        let normalizedArguments = try MCPRequestFactory.normalizedToolArguments(arguments); try await ensureConnected()
        let response = try await request(method: MCPMethod.toolsCall, params: MCPRequestFactory.toolsCall(id: 0, name: toolName, arguments: normalizedArguments).params, context: context)
        return try decodeResult(response, as: MCPCallResult.self)
    }

    private func request(method: String, params: JSONValue?, context: MCPCallContext?) async throws -> JSONRPCResponse {
        let id = nextID; nextID += 1; let line = try MCPRequestFactory.encodeLine(JSONRPCRequest(id: id, method: method, params: params))
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                // Cancellation may arrive before this continuation is registered.
                guard !Task.isCancelled else { continuation.resume(throwing: MCPError.cancelled); return }
                pending[id] = .init(continuation: continuation, method: method, context: context)
                timeoutTasks[id] = Task { [weak self, requestTimeout] in try? await Task.sleep(for: requestTimeout); await self?.failPending(id: id, error: MCPError.timeout(method), reason: "request timed out") }
                Task { [weak self] in
                    do { guard let transport = await self?.transport else { await self?.failPending(id: id, error: MCPError.transportFailed("transport not started"), reason: "transport unavailable"); return }; await self?.markSent(id); try await transport.send(line) }
                    catch let error as MCPError { await self?.failPending(id: id, error: error, reason: "transport failed") }
                    catch { await self?.failPending(id: id, error: MCPError.transportFailed(error.localizedDescription), reason: "transport failed") }
                }
            }
        }, onCancel: { Task { await self.failPending(id: id, error: MCPError.cancelled, reason: "caller cancelled") } })
    }
    private func sendNotification(_ request: JSONRPCRequest) async throws { guard let transport else { throw MCPError.transportFailed("transport not started") }; try await transport.send(MCPRequestFactory.encodeLine(request)) }
    private func sendResponse(_ response: JSONRPCOutgoingResponse) async { guard let transport else { return }; try? await transport.send(MCPRequestFactory.encodeLine(response)) }

    private func ingest(_ line: String) {
        guard let message = try? MCPRequestFactory.decodeInbound(line) else { return }
        switch message {
        case let .response(response):
            // Client requests only use integers. String IDs cannot resolve them.
            guard case let .int(id)? = response.id else { return }
            resolvePending(id: id, response: response)
        case let .notification(notification):
            if notification.method == MCPMethod.cancelled { return }
        case let .serverRequest(request):
            Task { await self.handleServerRequest(request) }
        }
    }
    private func handleServerRequest(_ request: JSONRPCServerRequest) async {
        guard supportsDuplexServerRequests else { await close(); return }
        guard request.method == MCPMethod.elicitationCreate else {
            await sendResponse(.error(id: request.id, code: -32601, message: "Method not found")); return
        }
        guard let elicitation = MCPElicitationRequest(params: request.params), elicitation.isValidForInteractiveHandling else {
            await sendResponse(.error(id: request.id, code: -32602, message: "Invalid params")); return
        }
        // Count calls, not unique values: equal contexts must still fail closed.
        let eligible = pending.values.compactMap(\.context)
        guard interactiveElicitationEnabled, let handler = serverRequestHandler, eligible.count == 1, let context = eligible.first else {
            await sendResponse(.result(id: request.id, .object(["action": .string("decline")]))); return
        }
        let disposition = await handler(request, context)
        switch disposition { case let .result(result): await sendResponse(.result(id: request.id, result)); case let .error(code, message): await sendResponse(.error(id: request.id, code: code, message: message)) }
    }
    private func markSent(_ id: Int) { sentRequestIDs.insert(id) }
    private func resolvePending(id: Int, response: JSONRPCResponse) { timeoutTasks.removeValue(forKey: id)?.cancel(); sentRequestIDs.remove(id); pending.removeValue(forKey: id)?.continuation.resume(returning: response) }
    private func failPending(id: Int, error: Error, reason: String) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        guard let pending = pending.removeValue(forKey: id) else { return }
        if pending.method != MCPMethod.initialize, sentRequestIDs.remove(id) != nil { Task { try? await self.sendNotification(MCPRequestFactory.cancelled(id: id, reason: reason)) } }
        pending.continuation.resume(throwing: error)
    }
    private func failAllPending(_ error: Error, reason: String) { let ids = Array(pending.keys); for id in ids { failPending(id: id, error: error, reason: reason) } }
    private func decodeResult<T: Decodable>(_ response: JSONRPCResponse, as type: T.Type) throws -> T { if let error = response.error { throw MCPError.rpc(code: error.code, message: error.message) }; guard let result = response.result else { throw MCPError.decoding("missing result for \(T.self)") }; do { return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(result)) } catch { throw MCPError.decoding(error.localizedDescription) } }
}
