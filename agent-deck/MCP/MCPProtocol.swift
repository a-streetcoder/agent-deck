import Foundation

/// JSON-RPC 2.0 + MCP wire types for talking to MCP servers over a line-delimited
/// transport. Reuses `JSONValue` (PiAgentSessionModels.swift) for free-form payloads.

/// JSON-RPC request identifiers are opaque: string and integer identifiers are distinct.
nonisolated enum RPCID: Codable, Hashable, Sendable {
    case int(Int)
    case string(String)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else { throw DecodingError.typeMismatch(RPCID.self, .init(codingPath: decoder.codingPath, debugDescription: "JSON-RPC id must be a string, integer, or null")) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self { case let .int(value): try container.encode(value); case let .string(value): try container.encode(value); case .null: try container.encodeNil() }
    }
}

nonisolated struct JSONRPCRequest: Encodable, Sendable {
    var jsonrpc = "2.0"
    var id: RPCID?
    var method: String
    var params: JSONValue?

    init(id: Int?, method: String, params: JSONValue? = nil) { self.id = id.map(RPCID.int); self.method = method; self.params = params }
    init(id: RPCID?, method: String, params: JSONValue? = nil) { self.id = id; self.method = method; self.params = params }
}

nonisolated struct JSONRPCErrorBody: Codable, Hashable, Sendable { var code: Int; var message: String; var data: JSONValue? }
nonisolated struct JSONRPCResponse: Decodable, Sendable { var jsonrpc: String?; var id: RPCID?; var result: JSONValue?; var error: JSONRPCErrorBody?; var method: String?; var isNotification: Bool { id == nil && method != nil } }
nonisolated struct JSONRPCServerRequest: Sendable { let id: RPCID; let method: String; let params: JSONValue? }
nonisolated struct JSONRPCNotification: Sendable { let method: String; let params: JSONValue? }

/// Explicitly distinguishes a response from a server-originated request. A request's
/// ID is never used to resolve a client-originated continuation.
nonisolated enum JSONRPCInboundMessage: Sendable {
    case response(JSONRPCResponse)
    case serverRequest(JSONRPCServerRequest)
    case notification(JSONRPCNotification)
}

nonisolated struct JSONRPCOutgoingResponse: Encodable, Sendable {
    var jsonrpc = "2.0"; var id: RPCID; var result: JSONValue?; var error: JSONRPCErrorBody?
    static func result(id: RPCID, _ result: JSONValue) -> Self { .init(id: id, result: result, error: nil) }
    static func error(id: RPCID, code: Int, message: String) -> Self { .init(id: id, result: nil, error: .init(code: code, message: message, data: nil)) }
}

// MARK: - Elicitation

/// Forward-compatible representation of `elicitation/create`. Elicitation was added
/// after Agent Deck's 2025-03-26 handshake, so this is defensive only until a UI exists.
nonisolated struct MCPElicitationRequest: Sendable {
    let id: RPCID
    let message: String?
    let title: String?
    let requestedSchema: JSONValue?
    let content: JSONValue?
    let meta: MCPElicitationMeta
    /// Full params retained for diagnostics without rendering or logging values.
    let rawParams: JSONValue?

    init?(params: JSONValue?) { self.init(id: .null, params: params) }

    init?(id: RPCID, params: JSONValue?) {
        guard case let .object(values)? = params else { return nil }
        self.id = id
        message = values["message"]?.stringValue
        title = values["title"]?.stringValue
        requestedSchema = values["requestedSchema"]
        content = values["content"]
        meta = MCPElicitationMeta(value: values["_meta"])
        rawParams = params
    }

    /// The 2025-06-18 shape requires a message and an object schema.
    var isValidForInteractiveHandling: Bool {
        guard let message, !message.isEmpty,
              case let .object(schema)? = requestedSchema,
              schema["type"]?.stringValue == "object",
              case .object? = schema["properties"] else { return false }
        return true
    }

    /// Phase 2B intentionally supports confirmation-only elicitation, never forms.
    var isConfirmationOnly: Bool {
        guard isValidForInteractiveHandling,
              case let .object(schema)? = requestedSchema,
              case let .object(properties)? = schema["properties"], properties.isEmpty else { return false }
        guard let required = schema["required"] else { return true }
        guard case let .array(values) = required else { return false }
        return values.isEmpty
    }
}

nonisolated struct MCPElicitationMeta: Sendable {
    /// Known persistence modes only; unknown modes remain untrusted in `raw`.
    let persistenceModes: Set<PersistenceMode>
    let raw: JSONValue?
    enum PersistenceMode: String, Sendable, Hashable { case none, session, persistent }
    init(value: JSONValue?) {
        raw = value
        guard case let .object(meta)? = value,
              case let .array(modes)? = meta["persist"] else { persistenceModes = []; return }
        persistenceModes = Set(modes.compactMap { $0.stringValue }.compactMap(PersistenceMode.init(rawValue:)))
    }
}

// MARK: - MCP domain types
nonisolated struct MCPToolDescriptor: Decodable, Hashable, Sendable { var name: String; var description: String?; var inputSchema: JSONValue? }
nonisolated struct MCPToolsListResult: Decodable, Hashable, Sendable { var tools: [MCPToolDescriptor]; var nextCursor: String? }
nonisolated struct MCPContentBlock: Decodable, Hashable, Sendable { var type: String; var text: String?; var data: String?; var mimeType: String?; var url: String? }
nonisolated struct MCPCallResult: Decodable, Hashable, Sendable { var content: [MCPContentBlock]?; var isError: Bool?; var combinedText: String { (content ?? []).map { $0.type == "text" ? ($0.text ?? "") : ($0.text?.isEmpty == false ? $0.text! : "[\($0.type) content]") }.joined(separator: "\n") } }

/// Immutable call provenance. It deliberately contains identifiers rather than data
/// payloads; never write it to logs with project paths or request arguments.
nonisolated struct MCPCallContext: Sendable, Hashable {
    let sessionID: UUID
    let projectID: String?
    let server: String
    let tool: String
    let requestingAgent: String?
    let subagentRunID: UUID?
    init(sessionID: UUID, projectID: String?, server: String, tool: String, requestingAgent: String? = nil, subagentRunID: UUID? = nil) { self.sessionID = sessionID; self.projectID = projectID; self.server = server; self.tool = tool; self.requestingAgent = requestingAgent; self.subagentRunID = subagentRunID }
}

nonisolated enum MCPServerRequestDisposition: Sendable { case result(JSONValue); case error(code: Int, message: String) }
typealias MCPServerRequestHandler = @Sendable (JSONRPCServerRequest, MCPCallContext?) async -> MCPServerRequestDisposition

nonisolated enum MCPMethod { static let initialize = "initialize"; static let initialized = "notifications/initialized"; static let toolsList = "tools/list"; static let toolsCall = "tools/call"; static let cancelled = "notifications/cancelled"; static let elicitationCreate = "elicitation/create" }
nonisolated enum MCPProtocolVersion {
    static let preferred = "2025-03-26"
    static let elicitationIntroduced = "2025-06-18"
    static func supportsElicitation(_ version: String) -> Bool { version >= elicitationIntroduced }
}

nonisolated struct MCPInitializeResult: Decodable, Sendable {
    let protocolVersion: String
    let capabilities: JSONValue?
}

nonisolated enum MCPRequestFactory {
    static func initialize(id: Int, clientName: String, clientVersion: String, supportsElicitation: Bool = false) -> JSONRPCRequest {
        // Do not change the installed helper's 2025-03-26 handshake unless a real
        // handler is present on a genuinely duplex transport.
        let version = supportsElicitation ? MCPProtocolVersion.elicitationIntroduced : MCPProtocolVersion.preferred
        let capabilities: JSONValue = supportsElicitation ? .object(["elicitation": .object([:])]) : .object([:])
        return JSONRPCRequest(id: id, method: MCPMethod.initialize, params: .object(["protocolVersion": .string(version), "capabilities": capabilities, "clientInfo": .object(["name": .string(clientName), "version": .string(clientVersion)])]))
    }
    static func initialized() -> JSONRPCRequest { JSONRPCRequest(id: Optional<Int>.none, method: MCPMethod.initialized, params: .object([:])) }
    static func toolsList(id: Int, cursor: String?) -> JSONRPCRequest { JSONRPCRequest(id: id, method: MCPMethod.toolsList, params: cursor.map { .object(["cursor": .string($0)]) }) }
    static func toolsCall(id: Int, name: String, arguments: JSONValue?) -> JSONRPCRequest { JSONRPCRequest(id: id, method: MCPMethod.toolsCall, params: .object(["name": .string(name), "arguments": arguments ?? .object([:])])) }
    /// The only elicitation completion shape emitted by Agent Deck. Persistence is
    /// deliberately absent until the helper's extension encoding is verified.
    static func elicitationResponse(action: String) -> JSONValue {
        .object(["action": .string(action), "content": .object([:])])
    }
    static func cancelled(id: Int, reason: String) -> JSONRPCRequest { JSONRPCRequest(id: Optional<Int>.none, method: MCPMethod.cancelled, params: .object(["requestId": .number(Double(id)), "reason": .string(reason)])) }
    static func normalizedToolArguments(_ arguments: JSONValue?) throws -> JSONValue {
        guard let arguments else { return .object([:]) }; switch arguments { case let .object(object): return .object(object); case .null: return .object([:]); case let .string(raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines); guard !trimmed.isEmpty else { return .object([:]) }; guard let data = trimmed.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) else { throw MCPError.invalidArguments("MCP tool arguments must be a JSON object; received a malformed JSON string.") }; guard let dict = parsed as? [String: Any], let normalized = JSONValue.fromFoundation(dict) else { throw MCPError.invalidArguments("MCP tool arguments must be a JSON object; received a JSON string that did not parse to an object.") }; return normalized
        default: throw MCPError.invalidArguments("MCP tool arguments must be a JSON object.") }
    }
    static func encodeLine<T: Encodable>(_ message: T) throws -> String { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return String(decoding: try encoder.encode(message), as: UTF8.self) + "\n" }
    static func decode(_ line: String) throws -> JSONRPCResponse { try JSONDecoder().decode(JSONRPCResponse.self, from: Data(line.utf8)) }
    static func decodeInbound(_ line: String) throws -> JSONRPCInboundMessage {
        let response = try decode(line)
        if let method = response.method {
            if let id = response.id, id != .null { return .serverRequest(.init(id: id, method: method, params: try params(from: line))) }
            return .notification(.init(method: method, params: try params(from: line)))
        }
        guard response.id != nil, response.result != nil || response.error != nil else { throw MCPError.decoding("malformed JSON-RPC message") }
        return .response(response)
    }
    private static func params(from line: String) throws -> JSONValue? {
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        return object?["params"].flatMap(JSONValue.fromFoundation)
    }
}

nonisolated enum MCPError: LocalizedError, Sendable, Equatable {
    case serverNotConfigured(String), transportFailed(String), rpc(code: Int, message: String), timeout(String), cancelled, decoding(String), invalidArguments(String), unsupportedTransport(MCPTransportKind), policyDenied(String), runtimeAuthorization(String), unauthorized
    var errorDescription: String? { switch self { case let .serverNotConfigured(name): return "MCP server \"\(name)\" is not configured."; case let .transportFailed(detail): return "MCP transport failed: \(detail)"; case let .rpc(code, message): return "MCP server error \(code): \(message)"; case let .timeout(detail): return "MCP request timed out: \(detail)"; case .cancelled: return "MCP request was cancelled."; case let .decoding(detail): return "Could not decode MCP response: \(detail)"; case let .invalidArguments(detail): return detail; case let .unsupportedTransport(kind): return "MCP transport \"\(kind.rawValue)\" is not supported yet."; case let .policyDenied(message), let .runtimeAuthorization(message): return message; case .unauthorized: return "MCP server requires sign-in (401). Connect the server to authorize." } }
}
