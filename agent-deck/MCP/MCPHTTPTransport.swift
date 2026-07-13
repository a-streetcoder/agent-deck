import Foundation

/// Streamable-HTTP transport (MCP 2025-03-26). Each outgoing JSON-RPC message is a
/// POST to the server URL; the response is either a single `application/json` body or
/// a `text/event-stream` of events, whose JSON-RPC payloads are fed back through
/// `onLine` so `MCPConnection` resolves them like the stdio path. The server's
/// `Mcp-Session-Id` (returned on initialize) is echoed on subsequent requests.
///
/// Auth: a `bearerToken` (from the OAuth store) is sent as `Authorization: Bearer …`;
/// any static headers from config are sent verbatim. A 401 surfaces as
/// `MCPError.unauthorized` so the Connect flow can kick in.
actor MCPHTTPTransport: MCPTransport {
    nonisolated var supportsDuplexServerRequests: Bool { false }
    private let url: URL
    private let extraHeaders: [String: String]
    private var bearerToken: String?
    /// Supplies a fresh OAuth access token before each request (refreshing as needed).
    private let tokenProvider: (@Sendable () async -> String?)?
    private var sessionID: String?
    private var onLine: (@Sendable (String) -> Void)?
    private var onClose: (@Sendable (MCPError?) -> Void)?
    private let session: URLSession

    init(url: URL, headers: [String: String] = [:], bearerToken: String? = nil,
         tokenProvider: (@Sendable () async -> String?)? = nil) {
        self.url = url
        self.extraHeaders = headers
        self.bearerToken = bearerToken
        self.tokenProvider = tokenProvider
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: configuration)
    }

    /// Convenience for the default transport factory. Throws if the config has no URL.
    init(config: MCPServerConfig, bearerToken: String? = nil,
         tokenProvider: (@Sendable () async -> String?)? = nil) throws {
        guard let raw = config.url, let url = URL(string: raw) else {
            throw MCPError.transportFailed("remote server has no valid url")
        }
        self.init(url: url, headers: config.headers ?? [:], bearerToken: bearerToken, tokenProvider: tokenProvider)
    }

    func start(onLine: @escaping @Sendable (String) -> Void,
               onClose: @escaping @Sendable (MCPError?) -> Void) async throws {
        self.onLine = onLine
        self.onClose = onClose
    }

    func send(_ line: String) async throws {
        if let tokenProvider { bearerToken = await tokenProvider() ?? bearerToken }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let bearerToken { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = Data((line.hasSuffix("\n") ? String(line.dropLast()) : line).utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MCPError.transportFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.transportFailed("no HTTP response")
        }
        if let newSession = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !newSession.isEmpty {
            sessionID = newSession
        }
        if http.statusCode == 401 { throw MCPError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.transportFailed("HTTP \(http.statusCode)")
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let body = String(decoding: data, as: UTF8.self)
        if contentType.contains("text/event-stream") {
            for payload in Self.parseSSE(body) { onLine?(payload) }
        } else if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onLine?(body)
        }
        // 202 Accepted with empty body (a notification ack) → nothing to deliver.
    }

    func close() async {
        // Best-effort session teardown; ignore failures.
        if sessionID != nil {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            if let bearerToken { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
            _ = try? await session.data(for: request)
        }
        session.invalidateAndCancel()
    }

    /// Extracts the JSON payloads from `data:` fields of an SSE body. Multi-line data
    /// within one event is concatenated; events are separated by blank lines.
    nonisolated static func parseSSE(_ body: String) -> [String] {
        var events: [String] = []
        var dataLines: [String] = []
        func flush() {
            if !dataLines.isEmpty {
                let joined = dataLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { events.append(joined) }
                dataLines.removeAll()
            }
        }
        let normalizedBody = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalizedBody.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix(":") { continue } // comment
            if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
            // other fields (event:, id:, retry:) are ignored for v1
        }
        flush()
        return events
    }
}
