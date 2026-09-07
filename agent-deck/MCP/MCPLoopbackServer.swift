import Foundation
import Network

/// A one-shot loopback HTTP server that captures the OAuth redirect. Listens on a
/// random `127.0.0.1` port, answers the browser with a "you can close this" page, and
/// delivers the redirect's query params (code/state or error). All continuation and
/// param access is funneled through `queue`, so the callback can arrive before or after
/// `waitForCallback()` without a race.
nonisolated final class MCPLoopbackServer: @unchecked Sendable {
    /// `data:` URI of the app icon, set once at startup by the app so the success
    /// page can show the brand mark (the loopback can't read app resources directly).
    nonisolated(unsafe) static var brandIconDataURI: String?

    private let listener: NWListener
    private let queue = DispatchQueue(label: "agent-deck.mcp.oauth.loopback")
    private var paramsContinuation: CheckedContinuation<[String: String], Error>?
    private var pendingParams: [String: String]?
    private(set) var port: UInt16 = 0

    /// Creates the loopback listener. Pass `port` to bind a specific loopback port when
    /// the OAuth client requires a fixed pre-registered redirect URI; otherwise the OS
    /// assigns a random ephemeral port (the default for Dynamic Client Registration).
    init(port: UInt16? = nil) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback
        if let port, let endpointPort = NWEndpoint.Port(rawValue: port) {
            listener = try NWListener(using: parameters, on: endpointPort)
        } else {
            listener = try NWListener(using: parameters)
        }
    }

    /// Starts listening and returns the assigned loopback port.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = self?.listener.port?.rawValue {
                        self?.port = port
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: MCPError.transportFailed("no loopback port"))
                    }
                case let .failed(error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    /// Awaits the redirect; returns its query params. Times out after `timeout` seconds.
    func waitForCallback(timeout: TimeInterval = 300) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let pending = self.pendingParams {
                    self.pendingParams = nil
                    continuation.resume(returning: pending)
                    return
                }
                self.paramsContinuation = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    if let waiting = self.paramsContinuation {
                        self.paramsContinuation = nil
                        waiting.resume(throwing: MCPError.timeout("OAuth callback"))
                    }
                }
            }
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let params = Self.parseQuery(fromRequestLine: request)
            let html = Self.successPageHTML()
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            // Already on `queue` (receive completes there) — deliver directly.
            if let waiting = self.paramsContinuation {
                self.paramsContinuation = nil
                waiting.resume(returning: params)
            } else {
                self.pendingParams = params
            }
        }
    }

    /// A centered, light/dark-aware "you can close this" page with the app icon.
    static func successPageHTML() -> String {
        let iconTag = brandIconDataURI.map {
            "<img src=\"\($0)\" alt=\"Agent Deck\" width=\"72\" height=\"72\" style=\"border-radius:18px;box-shadow:0 6px 18px rgba(0,0,0,.18);margin-bottom:22px\" />"
        } ?? ""
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Agent Deck</title>
        <style>
          :root { color-scheme: light dark; }
          * { box-sizing: border-box; }
          body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center;
                 font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',Helvetica,sans-serif;
                 background:#0c0c10; color:#f5f5f7; }
          .card { text-align:center; padding:44px 48px; border-radius:24px; max-width:440px;
                  background:#16161c; border:1px solid rgba(255,255,255,.06); }
          h1 { font-size:21px; font-weight:700; margin:0 0 10px; letter-spacing:-.2px; }
          p { font-size:14px; line-height:1.55; margin:0; opacity:.7; }
          .badge { display:inline-flex; align-items:center; gap:7px; margin-top:22px; padding:7px 14px;
                   border-radius:999px; background:rgba(52,199,89,.14); color:#34c759;
                   font-size:13px; font-weight:600; }
          .dot { width:8px; height:8px; border-radius:50%; background:#34c759; }
          @media (prefers-color-scheme: light) {
            body { background:#f2f2f7; color:#1c1c1e; }
            .card { background:#fff; border-color:rgba(0,0,0,.06); box-shadow:0 12px 44px rgba(0,0,0,.10); }
          }
        </style></head>
        <body><div class="card">
          \(iconTag)
          <h1>Connected to Agent Deck</h1>
          <p>Authentication complete. You can close this window and return to Agent Deck.</p>
          <div class="badge"><span class="dot"></span>Signed in</div>
        </div></body></html>
        """
    }

    /// Parses the query of an HTTP request's first line: `GET /cb?code=…&state=… HTTP/1.1`.
    static func parseQuery(fromRequestLine request: String) -> [String: String] {
        let firstLine = request.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first.map(String.init) ?? request
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, let questionMark = parts[1].firstIndex(of: "?") else { return [:] }
        let query = parts[1][parts[1].index(after: questionMark)...]
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            result[key] = value
        }
        return result
    }
}
