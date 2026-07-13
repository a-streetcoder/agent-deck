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
    private let clientName: String; private let clientVersion: String; private let requestTimeout: Duration; private let interactiveRequestTimeout: Duration
    private let serverRequestHandler: MCPServerRequestHandler?
    private var transport: MCPTransport?; private var connectTask: Task<Void, Error>?; private var isConnected = false
    private var nextID = 1
    private var supportsDuplexServerRequests = false
    private var interactiveElicitationEnabled = false
    private struct Pending {
        let continuation: CheckedContinuation<JSONRPCResponse, Error>
        let method: String
        let context: MCPCallContext?
        var sendStarted = false
    }
    private var pending: [Int: Pending] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    /// Elicitation work is bound to the one client tools/call that caused it.
    private var serverRequestTasks: [Int: Task<Void, Never>] = [:]

    init(name: String, config: MCPServerConfig, clientName: String = "Agent Deck", clientVersion: String = "1.0", requestTimeout: Duration = .seconds(30), interactiveRequestTimeout: Duration? = nil, serverRequestHandler: MCPServerRequestHandler? = nil, transportFactory: @escaping TransportFactory = MCPConnection.defaultTransportFactory) {
        self.name = name; self.config = config; self.clientName = clientName; self.clientVersion = clientVersion; self.requestTimeout = requestTimeout; self.interactiveRequestTimeout = interactiveRequestTimeout ?? requestTimeout; self.serverRequestHandler = serverRequestHandler; self.transportFactory = transportFactory
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
            // The server must select exactly the version we offered for elicitation;
            // accepting a future string would incorrectly assume an unknown shape.
            interactiveElicitationEnabled = offerElicitation && selected.protocolVersion == MCPProtocolVersion.elicitationIntroduced
            if offerElicitation, !interactiveElicitationEnabled {
                await transport.close()
                self.transport = nil
                throw MCPError.transportFailed("server selected unsupported MCP protocol version")
            }
        } else if offerElicitation {
            await transport.close()
            self.transport = nil
            throw MCPError.decoding("initialize response missing protocol version")
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
                let timeout = method == MCPMethod.toolsCall && serverRequestHandler != nil ? interactiveRequestTimeout : requestTimeout
                timeoutTasks[id] = Task { [weak self, timeout] in try? await Task.sleep(for: timeout); await self?.failPending(id: id, error: MCPError.timeout(method), reason: "request timed out") }
                // The detached task owns no request state. It must re-enter the actor
                // and prove the request is still pending before any transport write.
                Task { [weak self] in await self?.sendPending(id: id, line: line) }
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
            handleServerRequest(request)
        }
    }
    private func handleServerRequest(_ request: JSONRPCServerRequest) {
        guard supportsDuplexServerRequests else { Task { await self.close() }; return }
        guard request.method == MCPMethod.elicitationCreate else {
            Task { await self.sendResponse(.error(id: request.id, code: -32601, message: "Method not found")) }; return
        }
        guard let elicitation = MCPElicitationRequest(id: request.id, params: request.params), elicitation.isValidForInteractiveHandling, elicitation.isConfirmationOnly else {
            Task { await self.sendResponse(.result(id: request.id, MCPRequestFactory.elicitationResponse(action: "decline"))) }; return
        }
        // Count calls, not equal contexts: only one active client call may own a prompt.
        let eligible = pending.compactMap { id, item in item.context.map { (id, $0) } }
        guard interactiveElicitationEnabled, let handler = serverRequestHandler, eligible.count == 1, let owner = eligible.first else {
            Task { await self.sendResponse(.result(id: request.id, MCPRequestFactory.elicitationResponse(action: "decline"))) }; return
        }
        // A helper may not stack prompts on a single tools/call. The original
        // request remains its owner's responsibility; reject only the newcomer.
        guard serverRequestTasks[owner.0] == nil else {
            Task { await self.sendResponse(.result(id: request.id, MCPRequestFactory.elicitationResponse(action: "decline"))) }
            return
        }
        serverRequestTasks[owner.0] = Task { [weak self] in
            let disposition = await handler(request, owner.1)
            await self?.finishServerRequest(clientID: owner.0, serverID: request.id, disposition: disposition)
        }
    }
    private func finishServerRequest(clientID: Int, serverID: RPCID, disposition: MCPServerRequestDisposition) async {
        guard serverRequestTasks.removeValue(forKey: clientID) != nil else { return }
        switch disposition { case let .result(result): await sendResponse(.result(id: serverID, result)); case let .error(code, message): await sendResponse(.error(id: serverID, code: code, message: message)) }
    }
    private func sendPending(id: Int, line: String) async {
        guard var entry = pending[id], !entry.sendStarted else { return }
        guard let transport else { failPending(id: id, error: MCPError.transportFailed("transport not started"), reason: "transport unavailable"); return }
        entry.sendStarted = true
        pending[id] = entry
        do { try await transport.send(line) }
        catch let error as MCPError { failPending(id: id, error: error, reason: "transport failed") }
        catch { failPending(id: id, error: MCPError.transportFailed(error.localizedDescription), reason: "transport failed") }
    }
    private func resolvePending(id: Int, response: JSONRPCResponse) { timeoutTasks.removeValue(forKey: id)?.cancel(); serverRequestTasks.removeValue(forKey: id)?.cancel(); pending.removeValue(forKey: id)?.continuation.resume(returning: response) }
    private func failPending(id: Int, error: Error, reason: String) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        serverRequestTasks.removeValue(forKey: id)?.cancel()
        guard let entry = pending.removeValue(forKey: id) else { return }
        if entry.method != MCPMethod.initialize, entry.sendStarted { Task { try? await self.sendNotification(MCPRequestFactory.cancelled(id: id, reason: reason)) } }
        entry.continuation.resume(throwing: error)
    }
    private func failAllPending(_ error: Error, reason: String) { let ids = Array(pending.keys); for id in ids { failPending(id: id, error: error, reason: reason) } }
    private func decodeResult<T: Decodable>(_ response: JSONRPCResponse, as type: T.Type) throws -> T { if let error = response.error { throw MCPError.rpc(code: error.code, message: error.message) }; guard let result = response.result else { throw MCPError.decoding("missing result for \(T.self)") }; do { return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(result)) } catch { throw MCPError.decoding(error.localizedDescription) } }
}
