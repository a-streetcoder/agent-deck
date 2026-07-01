import CryptoKit
import XCTest
@testable import agent_deck

final class MCPOAuthTests: XCTestCase {
    // MARK: - PKCE + encoding

    func testPKCEChallengeIsSha256OfVerifier() {
        let pkce = MCPPKCE()
        XCTAssertGreaterThanOrEqual(pkce.verifier.count, 43)
        XCTAssertEqual(pkce.method, "S256")
        let expected = Data(SHA256.hash(data: Data(pkce.verifier.utf8))).base64URLEncodedString()
        XCTAssertEqual(pkce.challenge, expected)
        // base64url has no +, /, or =
        XCTAssertFalse(pkce.challenge.contains("+"))
        XCTAssertFalse(pkce.challenge.contains("/"))
        XCTAssertFalse(pkce.challenge.contains("="))
    }

    func testFormEncodePercentEncodes() {
        let encoded = MCPOAuthService.formEncode(["a b": "c/d", "x": "y"])
        XCTAssertTrue(encoded.contains("a%20b=c%2Fd"))
        XCTAssertTrue(encoded.contains("x=y"))
    }

    func testOriginStripsPath() {
        let origin = MCPOAuthService.originURL(URL(string: "https://mcp.amplitude.com/mcp?x=1")!)
        XCTAssertEqual(origin.absoluteString, "https://mcp.amplitude.com")
    }

    func testParseQueryFromRequestLine() {
        let params = MCPLoopbackServer.parseQuery(fromRequestLine: "GET /callback?code=abc&state=xy%20z HTTP/1.1\r\nHost: x")
        XCTAssertEqual(params["code"], "abc")
        XCTAssertEqual(params["state"], "xy z")
    }

    func testTokenResponseComputesExpiry() {
        let response = try! JSONDecoder().decode(MCPTokenResponse.self, from: Data(#"{"access_token":"A","expires_in":3600,"token_type":"Bearer"}"#.utf8))
        let now = Date()
        let tokens = response.tokens(now: now)
        XCTAssertEqual(tokens.accessToken, "A")
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(3600))
        XCTAssertFalse(tokens.isExpired) // ~1h out
        // A token expiring within 60s is treated as expired.
        let soon = MCPOAuthTokens(accessToken: "A", expiresAt: now.addingTimeInterval(30))
        XCTAssertTrue(soon.isExpired)
    }

    // MARK: - Discovery

    private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
        typealias Handler = @Sendable (URLRequest) throws -> (status: Int, headers: [String: String], body: Data)

        private static let lock = NSLock()
        nonisolated(unsafe) private static var handler: Handler?

        static func setHandler(_ newHandler: Handler?) {
            lock.lock()
            handler = newHandler
            lock.unlock()
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.lock()
            let handler = Self.handler
            Self.lock.unlock()

            guard let handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }

            do {
                let result = try handler(request)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: result.status,
                    httpVersion: "HTTP/1.1",
                    headerFields: result.headers
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: result.body)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ path: String) {
            lock.lock()
            storage.append(path)
            lock.unlock()
        }

        var paths: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private final class BodyRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ request: URLRequest) {
            let bodyData: Data
            if let httpBody = request.httpBody {
                bodyData = httpBody
            } else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                bodyData = data
            } else {
                bodyData = Data()
            }
            lock.lock()
            storage.append(String(decoding: bodyData, as: UTF8.self))
            lock.unlock()
        }

        var bodies: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private func makeMockOAuthService(store: MCPAuthStore? = nil, handler: @escaping MockURLProtocol.Handler) -> MCPOAuthService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.setHandler(handler)
        let session = URLSession(configuration: configuration)
        let authStore = store ?? MCPAuthStore(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcp-auth-\(UUID().uuidString).json"))
        return MCPOAuthService(session: session, store: authStore)
    }

    func testDiscoverUsesAdvertisedProtectedResourceMetadataFromBearerChallenge() async throws {
        let recorder = RequestRecorder()
        let service = makeMockOAuthService { request in
            recorder.append(request.url!.path)
            switch request.url!.path {
            case "/mcp":
                return (401, ["WWW-Authenticate": "Bearer resource_metadata=\"https://resource.example/.well-known/custom-resource\""], Data())
            case "/.well-known/custom-resource":
                return (200, [:], Data(#"{"authorization_servers":["https://auth.example"]}"#.utf8))
            case "/.well-known/oauth-authorization-server":
                return (200, [:], Data(#"{"authorization_endpoint":"https://auth.example/authorize","token_endpoint":"https://auth.example/token","registration_endpoint":"https://auth.example/register"}"#.utf8))
            default:
                return (404, [:], Data())
            }
        }

        let auth = try await service.discover(serverURL: URL(string: "https://resource.example/mcp")!)

        let requestedPaths = recorder.paths
        XCTAssertEqual(auth.authorizationEndpoint, "https://auth.example/authorize")
        XCTAssertEqual(auth.tokenEndpoint, "https://auth.example/token")
        XCTAssertEqual(Array(requestedPaths.prefix(2)), ["/mcp", "/.well-known/custom-resource"])
    }

    func testDiscoverFindsNonLeadingBearerChallenge() async throws {
        let recorder = RequestRecorder()
        let service = makeMockOAuthService { request in
            recorder.append(request.url!.path)
            switch request.url!.path {
            case "/mcp":
                return (401, ["WWW-Authenticate": "Digest realm=\"Bearer resource_metadata=not-a-challenge\", Basic realm=\"api\", Bearer resource_metadata=\"https://resource.example/.well-known/non-leading\""], Data())
            case "/.well-known/non-leading":
                return (200, [:], Data(#"{"authorization_servers":["https://auth.example"]}"#.utf8))
            case "/.well-known/oauth-authorization-server":
                return (200, [:], Data(#"{"authorization_endpoint":"https://auth.example/non-leading/authorize","token_endpoint":"https://auth.example/token"}"#.utf8))
            default:
                return (404, [:], Data())
            }
        }

        let auth = try await service.discover(serverURL: URL(string: "https://resource.example/mcp")!)

        let requestedPaths = recorder.paths
        XCTAssertEqual(auth.authorizationEndpoint, "https://auth.example/non-leading/authorize")
        XCTAssertEqual(Array(requestedPaths.prefix(2)), ["/mcp", "/.well-known/non-leading"])
    }

    func testDiscoverUsesCaseInsensitiveResourceMetadataFromLaterBearerChallenge() async throws {
        let recorder = RequestRecorder()
        let service = makeMockOAuthService { request in
            recorder.append(request.url!.path)
            switch request.url!.path {
            case "/mcp":
                return (401, ["WWW-Authenticate": "Bearer error=\"invalid_token\", Bearer realm=\"mcp\", RESOURCE_METADATA=\"https://resource.example/.well-known/case-insensitive\""], Data())
            case "/.well-known/case-insensitive":
                return (200, [:], Data(#"{"authorization_servers":["https://auth.example"]}"#.utf8))
            case "/.well-known/oauth-authorization-server":
                return (200, [:], Data(#"{"authorization_endpoint":"https://auth.example/case-insensitive/authorize","token_endpoint":"https://auth.example/token"}"#.utf8))
            default:
                return (404, [:], Data())
            }
        }

        let auth = try await service.discover(serverURL: URL(string: "https://resource.example/mcp")!)

        let requestedPaths = recorder.paths
        XCTAssertEqual(auth.authorizationEndpoint, "https://auth.example/case-insensitive/authorize")
        XCTAssertEqual(Array(requestedPaths.prefix(2)), ["/mcp", "/.well-known/case-insensitive"])
    }

    func testDiscoverParsesQuotedCommaAndEscapedResourceMetadata() async throws {
        let recorder = RequestRecorder()
        let service = makeMockOAuthService { request in
            recorder.append(request.url!.path)
            switch request.url!.path {
            case "/mcp":
                return (401, ["WWW-Authenticate": "Bearer resource_metadata=\"https://resource.example/.well-known/custom\\,meta\", error=\"invalid_token\""], Data())
            case "/.well-known/custom,meta":
                return (200, [:], Data(#"{"authorization_servers":["https://auth.example"]}"#.utf8))
            case "/.well-known/oauth-authorization-server":
                return (200, [:], Data(#"{"authorization_endpoint":"https://auth.example/quoted/authorize","token_endpoint":"https://auth.example/token"}"#.utf8))
            default:
                return (404, [:], Data())
            }
        }

        let auth = try await service.discover(serverURL: URL(string: "https://resource.example/mcp")!)

        let requestedPaths = recorder.paths
        XCTAssertEqual(auth.authorizationEndpoint, "https://auth.example/quoted/authorize")
        XCTAssertEqual(Array(requestedPaths.prefix(2)), ["/mcp", "/.well-known/custom,meta"])
    }

    func testDiscoverParsesUnquotedResourceMetadataToken() async throws {
        let recorder = RequestRecorder()
        let service = makeMockOAuthService { request in
            recorder.append(request.url!.path)
            switch request.url!.path {
            case "/mcp":
                return (401, ["WWW-Authenticate": "Bearer resource_metadata=https://resource.example/.well-known/unquoted, error=invalid_token"], Data())
            case "/.well-known/unquoted":
                return (200, [:], Data(#"{"authorization_servers":["https://auth.example"]}"#.utf8))
            case "/.well-known/oauth-authorization-server":
                return (200, [:], Data(#"{"authorization_endpoint":"https://auth.example/unquoted/authorize","token_endpoint":"https://auth.example/token"}"#.utf8))
            default:
                return (404, [:], Data())
            }
        }

        let auth = try await service.discover(serverURL: URL(string: "https://resource.example/mcp")!)

        let requestedPaths = recorder.paths
        XCTAssertEqual(auth.authorizationEndpoint, "https://auth.example/unquoted/authorize")
        XCTAssertEqual(Array(requestedPaths.prefix(2)), ["/mcp", "/.well-known/unquoted"])
    }

    func testDiscoverUsesPathScopedProtectedResourceMetadataBeforeOriginRoot() async throws {
        let recorder = RequestRecorder()
        let service = makeMockOAuthService { request in
            recorder.append(request.url!.path)
            switch request.url!.path {
            case "/tenant/mcp":
                return (401, ["WWW-Authenticate": "Bearer error=\"invalid_token\""], Data())
            case "/.well-known/oauth-protected-resource/tenant/mcp":
                return (200, [:], Data(#"{"authorization_servers":["https://auth.example"]}"#.utf8))
            case "/.well-known/oauth-authorization-server":
                return (200, [:], Data(#"{"authorization_endpoint":"https://auth.example/authorize","token_endpoint":"https://auth.example/token"}"#.utf8))
            default:
                return (404, [:], Data())
            }
        }

        let auth = try await service.discover(serverURL: URL(string: "https://resource.example/tenant/mcp")!)

        let requestedPaths = recorder.paths
        XCTAssertEqual(auth.authorizationEndpoint, "https://auth.example/authorize")
        XCTAssertTrue(requestedPaths.contains("/.well-known/oauth-protected-resource/tenant/mcp"))
        XCTAssertFalse(requestedPaths.contains("/.well-known/oauth-protected-resource"))
    }

    func testDiscoverSupportsPathfulAuthorizationServerMetadataURLs() async throws {
        let recorder = RequestRecorder()
        let service = makeMockOAuthService { request in
            recorder.append(request.url!.path)
            switch request.url!.path {
            case "/mcp":
                return (404, [:], Data())
            case "/.well-known/oauth-protected-resource/mcp":
                return (404, [:], Data())
            case "/.well-known/oauth-protected-resource":
                return (200, [:], Data(#"{"authorization_servers":["https://auth.example/issuer/a"]}"#.utf8))
            case "/.well-known/oauth-authorization-server/issuer/a":
                return (200, [:], Data(#"{"authorization_endpoint":"https://auth.example/issuer/a/authorize","token_endpoint":"https://auth.example/issuer/a/token"}"#.utf8))
            default:
                return (404, [:], Data())
            }
        }

        let auth = try await service.discover(serverURL: URL(string: "https://resource.example/mcp")!)

        let requestedPaths = recorder.paths
        XCTAssertEqual(auth.authorizationEndpoint, "https://auth.example/issuer/a/authorize")
        XCTAssertTrue(requestedPaths.contains("/.well-known/oauth-authorization-server/issuer/a"))
        XCTAssertFalse(requestedPaths.contains("/issuer/a/.well-known/oauth-authorization-server"))
    }

    func testDiscoverPreservesOriginRootProtectedResourceFlow() async throws {
        let recorder = RequestRecorder()
        let service = makeMockOAuthService { request in
            recorder.append(request.url!.path)
            switch request.url!.path {
            case "/mcp":
                return (404, [:], Data())
            case "/.well-known/oauth-protected-resource/mcp":
                return (404, [:], Data())
            case "/.well-known/oauth-protected-resource":
                return (200, [:], Data(#"{"authorization_servers":["https://resource.example"]}"#.utf8))
            case "/.well-known/oauth-authorization-server":
                return (200, [:], Data(#"{"authorization_endpoint":"https://resource.example/authorize","token_endpoint":"https://resource.example/token"}"#.utf8))
            default:
                return (404, [:], Data())
            }
        }

        let auth = try await service.discover(serverURL: URL(string: "https://resource.example/mcp")!)

        let requestedPaths = recorder.paths
        XCTAssertEqual(auth.authorizationEndpoint, "https://resource.example/authorize")
        XCTAssertEqual(auth.tokenEndpoint, "https://resource.example/token")
        XCTAssertTrue(requestedPaths.contains("/.well-known/oauth-protected-resource"))
    }

    // MARK: - Store

    func testAuthStoreRoundTripAndExpiry() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcp-auth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MCPAuthStore(url: url)

        var auth = MCPServerAuth()
        auth.clientID = "cid"
        auth.clientSecret = "secret"
        auth.scope = "read tools"
        auth.tokenEndpoint = "https://x/token"
        auth.tokens = MCPOAuthTokens(accessToken: "tok", refreshToken: "r", tokenType: "Bearer", expiresAt: Date().addingTimeInterval(3600))
        await store.setAuth(auth, for: "srv")

        let token = await store.validAccessToken(for: "srv")
        XCTAssertEqual(token, "tok")
        let connected = await store.isConnected("srv")
        XCTAssertTrue(connected)

        // A fresh store reading the same file sees it persisted.
        let reopened = MCPAuthStore(url: url)
        let reopenedAuth = await reopened.auth(for: "srv")
        XCTAssertEqual(reopenedAuth?.clientID, "cid")
        XCTAssertEqual(reopenedAuth?.clientSecret, "secret")
        XCTAssertEqual(reopenedAuth?.scope, "read tools")

        // Expired token is not returned.
        var expired = auth
        expired.tokens?.expiresAt = Date().addingTimeInterval(-10)
        await store.setAuth(expired, for: "srv")
        let expiredToken = await store.validAccessToken(for: "srv")
        XCTAssertNil(expiredToken)
    }

    // MARK: - Pre-registered client behavior

    func testConnectWithoutRegistrationEndpointAndWithoutClientFails() async throws {
        let recorder = RequestRecorder()
        let store = MCPAuthStore(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcp-auth-\(UUID().uuidString).json"))
        let service = makeMockOAuthService(store: store) { request in
            recorder.append(request.url!.path)
            switch request.url!.path {
            case "/mcp", "/.well-known/oauth-protected-resource/mcp":
                return (404, [:], Data())
            case "/.well-known/oauth-protected-resource":
                return (200, [:], Data(#"{"authorization_servers":["https://auth.example"]}"#.utf8))
            case "/.well-known/oauth-authorization-server":
                return (200, [:], Data(#"{"authorization_endpoint":"https://auth.example/authorize","token_endpoint":"https://auth.example/token"}"#.utf8))
            default:
                return (404, [:], Data())
            }
        }

        do {
            try await service.connect(serverName: "fixture", serverURLString: "https://resource.example/mcp")
            XCTFail("Expected connect to require a pre-registered client")
        } catch {
            XCTAssertTrue(String(describing: error).contains("pre-registered client"))
        }
        XCTAssertFalse(recorder.paths.contains("/register"))
    }

    func testRefreshIncludesPreconfiguredClientSecretAndScope() async throws {
        let bodies = BodyRecorder()
        let store = MCPAuthStore(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcp-auth-\(UUID().uuidString).json"))
        var auth = MCPServerAuth()
        auth.clientID = "client-123"
        auth.clientSecret = "secret-456"
        auth.scope = "read tools"
        auth.tokenEndpoint = "https://auth.example/token"
        auth.tokens = MCPOAuthTokens(accessToken: "old", refreshToken: "refresh-789", expiresAt: Date().addingTimeInterval(-120))
        await store.setAuth(auth, for: "fixture")

        let service = makeMockOAuthService(store: store) { request in
            if request.url!.path == "/token" {
                bodies.append(request)
                return (200, [:], Data(#"{"access_token":"new-access","refresh_token":"new-refresh","token_type":"Bearer","expires_in":3600}"#.utf8))
            }
            return (404, [:], Data())
        }

        let token = try await service.refresh(serverName: "fixture")

        XCTAssertEqual(token, "new-access")
        let body = try XCTUnwrap(bodies.bodies.first)
        XCTAssertTrue(body.contains("client_id=client-123"))
        XCTAssertTrue(body.contains("client_secret=secret-456"))
        XCTAssertTrue(body.contains("scope=read%20tools"))
    }

    // MARK: - Loopback round-trip

    func testLoopbackServerCapturesRedirectParams() async throws {
        let server = try MCPLoopbackServer()
        let port = try await server.start()
        defer { server.stop() }

        Task.detached {
            _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/callback?code=THECODE&state=S1")!)
        }
        let params = try await server.waitForCallback(timeout: 10)
        XCTAssertEqual(params["code"], "THECODE")
        XCTAssertEqual(params["state"], "S1")
    }

    // MARK: - Full connect() flow against a mock OAuth + MCP server

    private func resolveNode() -> String? {
        ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node",
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/node/bin/node").path]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static let mockOAuthServer = """
    const http = require('http');
    const url = require('url');
    let base = '';
    const server = http.createServer((req, res) => {
      const u = url.parse(req.url, true);
      const json = (o) => { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(o)); };
      if (u.pathname === '/.well-known/oauth-protected-resource') return json({ resource: base + '/mcp', authorization_servers: [base] });
      if (u.pathname === '/.well-known/oauth-authorization-server') return json({ authorization_endpoint: base + '/authorize', token_endpoint: base + '/token', registration_endpoint: base + '/register' });
      if (u.pathname === '/register' && req.method === 'POST') return json({ client_id: 'test-client' });
      if (u.pathname === '/authorize') { res.writeHead(302, { Location: u.query.redirect_uri + '?code=AUTHCODE&state=' + encodeURIComponent(u.query.state) }); return res.end(); }
      if (u.pathname === '/token' && req.method === 'POST') { let b=''; req.on('data',c=>b+=c); req.on('end',()=>{ json({ access_token: 'ACCESS123', refresh_token: 'REFRESH123', token_type: 'Bearer', expires_in: 3600 }); }); return; }
      res.writeHead(404); res.end();
    });
    server.listen(0, '127.0.0.1', () => { base = 'http://127.0.0.1:' + server.address().port; console.log('PORT ' + server.address().port); });
    """

    private static let preRegisteredOAuthServer = """
    const http = require('http');
    const url = require('url');
    let base = '';
    const server = http.createServer((req, res) => {
      const u = url.parse(req.url, true);
      const json = (status, o) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(o)); };
      if (u.pathname === '/.well-known/oauth-protected-resource') return json(200, { resource: base + '/mcp', authorization_servers: [base] });
      if (u.pathname === '/.well-known/oauth-authorization-server') return json(200, { authorization_endpoint: base + '/authorize', token_endpoint: base + '/token' });
      if (u.pathname === '/register') return json(500, { error: 'registration should not be called' });
      if (u.pathname === '/authorize') {
        if (u.query.client_id !== 'pre-client' || u.query.scope !== 'read tools') return json(400, { error: 'bad authorize request', query: u.query });
        res.writeHead(302, { Location: u.query.redirect_uri + '?code=AUTHCODE&state=' + encodeURIComponent(u.query.state) }); return res.end();
      }
      if (u.pathname === '/token' && req.method === 'POST') { let b=''; req.on('data',c=>b+=c); req.on('end',()=>{
        if (!b.includes('client_id=pre-client') || !b.includes('client_secret=pre-secret')) return json(400, { error: 'missing client credentials', body: b });
        json(200, { access_token: 'PREACCESS', refresh_token: 'PREREFRESH', token_type: 'Bearer', expires_in: 3600 });
      }); return; }
      res.writeHead(404); res.end();
    });
    server.listen(0, '127.0.0.1', () => { base = 'http://127.0.0.1:' + server.address().port; console.log('PORT ' + server.address().port); });
    """

    private func startMockServer(script scriptText: String? = nil) throws -> (process: Process, port: Int) {
        guard let node = resolveNode() else { throw XCTSkip("node not found; skipping OAuth flow test.") }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcp-oauth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("server.js")
        try (scriptText ?? Self.mockOAuthServer).write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [script.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let handle = pipe.fileHandleForReading
        let semaphore = DispatchSemaphore(value: 0)
        let collected = NSMutableString()
        DispatchQueue.global().async {
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                collected.append(String(decoding: data, as: UTF8.self))
                if collected.contains("PORT ") { break }
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 20) == .success,
              let match = (collected as String).range(of: #"PORT (\d+)"#, options: .regularExpression),
              let port = Int((collected as String)[match].dropFirst(5)) else {
            process.terminate(); throw XCTSkip("mock server did not start.")
        }
        return (process, port)
    }

    func testConnectRunsFullOAuthFlowAndStoresTokens() async throws {
        let fixture = try startMockServer()
        defer { fixture.process.terminate() }

        let storeURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcp-auth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = MCPAuthStore(url: storeURL)

        // Stub the "open browser" step: GET the authorize URL; URLSession follows the
        // 302 to the loopback, which captures the code — exactly like a real browser.
        let openURL: @Sendable (URL) -> Void = { authURL in
            Task.detached { _ = try? await URLSession.shared.data(from: authURL) }
        }
        let service = MCPOAuthService(session: .shared, store: store, openURL: openURL)

        try await service.connect(serverName: "fixture", serverURLString: "http://127.0.0.1:\(fixture.port)/mcp")

        let auth = await store.auth(for: "fixture")
        XCTAssertEqual(auth?.clientID, "test-client")
        XCTAssertEqual(auth?.tokens?.accessToken, "ACCESS123")
        XCTAssertEqual(auth?.tokens?.refreshToken, "REFRESH123")
        let validToken = await store.validAccessToken(for: "fixture")
        XCTAssertEqual(validToken, "ACCESS123")
    }

    func testConnectUsesPreconfiguredClientWhenRegistrationEndpointIsAbsent() async throws {
        let fixture = try startMockServer(script: Self.preRegisteredOAuthServer)
        defer { fixture.process.terminate() }

        let storeURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcp-auth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = MCPAuthStore(url: storeURL)
        var storedAuth = MCPServerAuth()
        storedAuth.clientID = "pre-client"
        storedAuth.clientSecret = "pre-secret"
        storedAuth.scope = "read tools"
        await store.setAuth(storedAuth, for: "fixture")

        let openURL: @Sendable (URL) -> Void = { authURL in
            Task.detached { _ = try? await URLSession.shared.data(from: authURL) }
        }
        let service = MCPOAuthService(session: .shared, store: store, openURL: openURL)

        try await service.connect(serverName: "fixture", serverURLString: "http://127.0.0.1:\(fixture.port)/mcp")

        let auth = await store.auth(for: "fixture")
        XCTAssertEqual(auth?.clientID, "pre-client")
        XCTAssertEqual(auth?.clientSecret, "pre-secret")
        XCTAssertEqual(auth?.scope, "read tools")
        XCTAssertEqual(auth?.tokens?.accessToken, "PREACCESS")
        XCTAssertEqual(auth?.tokens?.refreshToken, "PREREFRESH")
    }
}
