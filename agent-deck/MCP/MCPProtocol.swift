import Foundation

/// JSON-RPC 2.0 + MCP wire types for talking to MCP servers over a line-delimited
/// transport. Reuses `JSONValue` (PiAgentSessionModels.swift) for free-form payloads.

/// A JSON-RPC id, which a server echoes back so we can match a response to its
/// request. We always send integers; servers may reply with int, string, or null.
nonisolated enum RPCID: Codable, Hashable, Sendable {
    case int(Int)
    case string(String)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .int(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// An outgoing JSON-RPC request (or notification, when `id` is nil).
nonisolated struct JSONRPCRequest: Encodable, Sendable {
    var jsonrpc = "2.0"
    var id: RPCID?
    var method: String
    var params: JSONValue?

    init(id: Int?, method: String, params: JSONValue? = nil) {
        self.id = id.map(RPCID.int)
        self.method = method
        self.params = params
    }
}

nonisolated struct JSONRPCErrorBody: Decodable, Hashable, Sendable {
    var code: Int
    var message: String
    var data: JSONValue?
}

/// An incoming JSON-RPC message. Responses carry `id` + (`result` or `error`);
/// notifications carry `method` and no `id`.
nonisolated struct JSONRPCResponse: Decodable, Sendable {
    var jsonrpc: String?
    var id: RPCID?
    var result: JSONValue?
    var error: JSONRPCErrorBody?
    var method: String?

    var isNotification: Bool { id == nil && method != nil }
}

// MARK: - MCP domain types

nonisolated struct MCPToolDescriptor: Decodable, Hashable, Sendable {
    var name: String
    var description: String?
    var inputSchema: JSONValue?
}

nonisolated struct MCPToolsListResult: Decodable, Hashable, Sendable {
    var tools: [MCPToolDescriptor]
    var nextCursor: String?
}

/// A single content block from a `tools/call` result. v1 reads `text`; other block
/// types (image, resource) are surfaced as a placeholder by the renderer.
nonisolated struct MCPContentBlock: Decodable, Hashable, Sendable {
    var type: String
    var text: String?
}

nonisolated struct MCPCallResult: Decodable, Hashable, Sendable {
    var content: [MCPContentBlock]?
    var isError: Bool?

    /// Flattened text of the content blocks, with non-text blocks marked.
    var combinedText: String {
        (content ?? []).map { block in
            if block.type == "text" { return block.text ?? "" }
            if let text = block.text, !text.isEmpty { return text }
            return "[\(block.type) content]"
        }
        .joined(separator: "\n")
    }
}

/// MCP method names used in v1.
nonisolated enum MCPMethod {
    static let initialize = "initialize"
    static let initialized = "notifications/initialized"
    static let toolsList = "tools/list"
    static let toolsCall = "tools/call"
    static let cancelled = "notifications/cancelled"
}

/// The protocol version Agent Deck negotiates. Servers fall back as needed.
nonisolated enum MCPProtocolVersion {
    static let preferred = "2025-03-26"
}

/// Builders for the small set of requests v1 sends, plus newline framing helpers.
nonisolated enum MCPRequestFactory {
    static func initialize(id: Int, clientName: String, clientVersion: String) -> JSONRPCRequest {
        let params: JSONValue = .object([
            "protocolVersion": .string(MCPProtocolVersion.preferred),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(clientName),
                "version": .string(clientVersion)
            ])
        ])
        return JSONRPCRequest(id: id, method: MCPMethod.initialize, params: params)
    }

    static func initialized() -> JSONRPCRequest {
        JSONRPCRequest(id: nil, method: MCPMethod.initialized, params: .object([:]))
    }

    static func toolsList(id: Int, cursor: String?) -> JSONRPCRequest {
        let params: JSONValue? = cursor.map { .object(["cursor": .string($0)]) }
        return JSONRPCRequest(id: id, method: MCPMethod.toolsList, params: params)
    }

    static func toolsCall(id: Int, name: String, arguments: JSONValue?) -> JSONRPCRequest {
        let params: JSONValue = .object([
            "name": .string(name),
            "arguments": arguments ?? .object([:])
        ])
        return JSONRPCRequest(id: id, method: MCPMethod.toolsCall, params: params)
    }

    /// MCP `tools/call` requires an object-shaped `arguments` value. Pi/tool bridges
    /// can occasionally hand us an already-stringified JSON object; normalize that
    /// client-side so servers do not fail later with schema/Zod errors.
    static func normalizedToolArguments(_ arguments: JSONValue?) throws -> JSONValue {
        guard let arguments else { return .object([:]) }
        switch arguments {
        case let .object(object):
            return .object(object)
        case .null:
            return .object([:])
        case let .string(raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .object([:]) }
            guard let data = trimmed.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) else {
                throw MCPError.invalidArguments("MCP tool arguments must be a JSON object; received a malformed JSON string.")
            }
            guard let dictionary = parsed as? [String: Any],
                  let normalized = JSONValue.fromFoundation(dictionary),
                  case .object = normalized else {
                throw MCPError.invalidArguments("MCP tool arguments must be a JSON object; received a JSON string that did not parse to an object.")
            }
            return normalized
        default:
            throw MCPError.invalidArguments("MCP tool arguments must be a JSON object.")
        }
    }

    /// Encodes a request as a single newline-terminated JSON line.
    static func encodeLine(_ request: JSONRPCRequest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(request)
        let json = String(decoding: data, as: UTF8.self)
        return json + "\n"
    }

    /// Decodes a single response line.
    static func decode(_ line: String) throws -> JSONRPCResponse {
        try JSONDecoder().decode(JSONRPCResponse.self, from: Data(line.utf8))
    }
}

/// Errors surfaced by the MCP client.
nonisolated enum MCPError: LocalizedError, Sendable, Equatable {
    case serverNotConfigured(String)
    case transportFailed(String)
    case rpc(code: Int, message: String)
    case timeout(String)
    case cancelled
    case decoding(String)
    case invalidArguments(String)
    case unsupportedTransport(MCPTransportKind)
    /// HTTP 401 — the server requires authentication (drives the OAuth Connect flow).
    case unauthorized

    var errorDescription: String? {
        switch self {
        case let .serverNotConfigured(name): return "MCP server \"\(name)\" is not configured."
        case let .transportFailed(detail): return "MCP transport failed: \(detail)"
        case let .rpc(code, message): return "MCP server error \(code): \(message)"
        case let .timeout(detail): return "MCP request timed out: \(detail)"
        case .cancelled: return "MCP request was cancelled."
        case let .decoding(detail): return "Could not decode MCP response: \(detail)"
        case let .invalidArguments(detail): return detail
        case let .unsupportedTransport(kind): return "MCP transport \"\(kind.rawValue)\" is not supported yet."
        case .unauthorized: return "MCP server requires sign-in (401). Connect the server to authorize."
        }
    }
}
