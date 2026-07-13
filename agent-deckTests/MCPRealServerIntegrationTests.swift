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
        send({ jsonrpc: '2.0', id: msg.id, result: { content: [{ type: 'text', text: 'echo: ' + (args.message || '') }], isError: false } });
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
