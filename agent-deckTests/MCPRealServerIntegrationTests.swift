import XCTest
@testable import agent_deck

/// Exercises the REAL `MCPStdioTransport` (subprocess spawn + newline JSON-RPC over
/// stdio) against a tiny local Node MCP server, proving the full client path beyond
/// the in-process stub. Deterministic and fast; skipped only when `node` is absent.
final class MCPRealServerIntegrationTests: XCTestCase {
    /// Minimal MCP server: initialize handshake, one `echo` tool, tools/list + tools/call.
    private static let serverScript = """
    const readline = require('readline');
    const rl = readline.createInterface({ input: process.stdin });
    function send(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
    rl.on('line', (line) => {
      if (!line.trim()) return;
      let msg; try { msg = JSON.parse(line); } catch (e) { return; }
      if (msg.method === 'initialize') {
        send({ jsonrpc: '2.0', id: msg.id, result: { protocolVersion: '2025-03-26', capabilities: { tools: {} }, serverInfo: { name: 'fixture', version: '1' } } });
      } else if (msg.method === 'tools/list') {
        send({ jsonrpc: '2.0', id: msg.id, result: { tools: [
          { name: 'echo', description: 'Echo the message', inputSchema: { type: 'object', properties: { message: { type: 'string' } } } }
        ] } });
      } else if (msg.method === 'tools/call') {
        const args = (msg.params && msg.params.arguments) || {};
        const text = args.inspectEnvironment
          ? JSON.stringify({
              authExists: !!process.env.AUTH_TOKEN,
              authMatches: process.env.AUTH_TOKEN === 'TEST_TOKEN',
              overrideWins: process.env.HOME === '/configured-home',
              pathInherited: !!process.env.PATH,
              argumentLiteral: process.argv[2] === '${AUTH_TOKEN}'
            })
          : 'echo: ' + (args.message || '');
        send({ jsonrpc: '2.0', id: msg.id, result: { content: [{ type: 'text', text }], isError: false } });
      }
    });
    """

    private var scriptURL: URL!

    private func resolveNode() -> String? {
        let candidates = [
            "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/node/bin/node").path
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    override func setUpWithError() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcp-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scriptURL = dir.appendingPathComponent("server.js")
        try Self.serverScript.write(to: scriptURL, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let dir = scriptURL?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: dir) }
    }

    private func fixtureConfig() throws -> MCPServerConfig {
        guard let node = resolveNode() else { throw XCTSkip("node not found; skipping real-transport integration test.") }
        return MCPServerConfig(command: node, args: [scriptURL.path])
    }

    func testInitializeListAndCallOverRealStdioTransport() async throws {
        let connection = MCPConnection(name: "fixture", config: try fixtureConfig(), requestTimeout: .seconds(20))
        defer { Task { await connection.close() } }

        let tools = try await connection.listTools()
        XCTAssertEqual(tools.map(\.name), ["echo"])
        XCTAssertNotNil(tools.first?.inputSchema)

        let result = try await connection.callTool(name: "echo", arguments: .object(["message": .string("hello-mcp")]))
        XCTAssertEqual(result.isError, false)
        XCTAssertEqual(result.combinedText, "echo: hello-mcp")
    }

    func testConfiguredEnvironmentIsMergedAndArgumentsStayLiteral() async throws {
        var config = try fixtureConfig()
        config.args?.append("${AUTH_TOKEN}")
        config.env = ["AUTH_TOKEN": "TEST_TOKEN", "HOME": "/configured-home"]
        let connection = MCPConnection(name: "fixture", config: config, requestTimeout: .seconds(20))
        defer { Task { await connection.close() } }

        let result = try await connection.callTool(name: "echo", arguments: .object(["inspectEnvironment": .bool(true)]))
        let data = try XCTUnwrap(result.combinedText.data(using: .utf8))
        let flags = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Bool])
        XCTAssertEqual(flags["authExists"], true)
        XCTAssertEqual(flags["authMatches"], true)
        XCTAssertEqual(flags["overrideWins"], true)
        XCTAssertEqual(flags["pathInherited"], true)
        XCTAssertEqual(flags["argumentLiteral"], true)
    }

    func testEarlyExitSurfacesSanitizedStderr() async throws {
        guard let node = resolveNode() else { throw XCTSkip("node not found; skipping real-transport integration test.") }
        let exitScript = scriptURL.deletingLastPathComponent().appendingPathComponent("exit.js")
        try "console.error('useful diagnostic ' + process.env.AUTH_TOKEN); process.exit(7);"
            .write(to: exitScript, atomically: true, encoding: .utf8)
        let config = MCPServerConfig(command: node, args: [exitScript.path], env: ["AUTH_TOKEN": "TEST_TOKEN"])
        let connection = MCPConnection(name: "fixture", config: config, requestTimeout: .seconds(5))

        do {
            _ = try await connection.listTools()
            XCTFail("Expected the fixture to exit")
        } catch {
            let message = (error as? MCPError)?.errorDescription ?? error.localizedDescription
            XCTAssertTrue(message.contains("server exited with code 7"), message)
            XCTAssertTrue(message.contains("useful diagnostic"), message)
            XCTAssertFalse(message.contains("TEST_TOKEN"), message)
            XCTAssertTrue(message.contains("<redacted>"), message)
        }
    }

    func testManagerCatalogAndCallOverRealStdioTransport() async throws {
        let config = try fixtureConfig()
        let manager = MCPConnectionManager(requestTimeout: .seconds(20))
        await manager.configure(servers: [MCPServerEntry(name: "fixture", config: config, sourcePath: scriptURL.path)])
        defer { Task { await manager.shutdown() } }

        let catalog = await manager.discoverCatalog(serverNames: ["fixture"])
        XCTAssertEqual(catalog.map(\.qualifiedName), ["fixture/echo"])

        let result = try await manager.call(server: "fixture", tool: "echo", arguments: .object(["message": .string("via-manager")]), context: MCPCallContext(sessionID: UUID(), projectID: nil, server: "fixture", tool: "echo"))
        XCTAssertEqual(result.combinedText, "echo: via-manager")
    }
}
