import XCTest
@testable import agent_deck

final class MCPForeignConfigScannerTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcp-import-scanner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    private func write(_ text: String, to relativePath: String) throws {
        let url = tempRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testScansClaudeJSONAndSkipsExistingNamesCaseInsensitively() throws {
        try write(#"""
        { "mcpServers": {
            "GitHub": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"] },
            "Amplitude": { "url": "https://mcp.amplitude.com/mcp", "transport": "streamable-http" }
        } }
        """#, to: "Library/Application Support/Claude/claude_desktop_config.json")

        let scanner = MCPForeignConfigScanner(homeDirectory: tempRoot)
        let candidates = scanner.scan(excluding: ["github"])

        XCTAssertEqual(candidates.map(\.name), ["Amplitude"])
        XCTAssertEqual(candidates.first?.sourceName, "Claude Desktop")
        XCTAssertEqual(candidates.first?.config.url, "https://mcp.amplitude.com/mcp")
        XCTAssertEqual(candidates.first?.config.transport, .http)
    }

    func testParsesCodexTomlStdioAndHttpServers() {
        let parsed = MCPForeignConfigScanner.parseCodexTOML(#"""
        [mcp_servers.filesystem]
        command = "npx"
        args = ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
        env = { API_TOKEN = "secret" }
        env_vars = ["PASSTHROUGH_TOKEN"]
        cwd = "/tmp/project"

        [mcp_servers.remote]
        url = "https://example.com/mcp"
        transport = "streamable-http"
        http_headers = { XStatic = "yes" }
        bearer_token_env_var = "REMOTE_TOKEN"
        env_http_headers = { XDynamic = "DYNAMIC_TOKEN" }
        """#)
        let byName = Dictionary(uniqueKeysWithValues: parsed.map { ($0.name ?? "", $0.config) })

        XCTAssertEqual(byName["filesystem"]?.command, "npx")
        XCTAssertEqual(byName["filesystem"]?.args, ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"])
        XCTAssertEqual(byName["filesystem"]?.env?["API_TOKEN"], "secret")
        XCTAssertEqual(byName["filesystem"]?.env?["PASSTHROUGH_TOKEN"], "${PASSTHROUGH_TOKEN}")
        XCTAssertEqual(byName["filesystem"]?.cwd, "/tmp/project")
        XCTAssertEqual(byName["filesystem"]?.resolvedTransport, .stdio)
        XCTAssertEqual(byName["remote"]?.url, "https://example.com/mcp")
        XCTAssertEqual(byName["remote"]?.headers?["XStatic"], "yes")
        XCTAssertEqual(byName["remote"]?.headers?["Authorization"], "Bearer ${REMOTE_TOKEN}")
        XCTAssertEqual(byName["remote"]?.headers?["XDynamic"], "${DYNAMIC_TOKEN}")
        XCTAssertEqual(byName["remote"]?.transport, .http)
    }

    func testCodexTomlSupportsEnvAndHeadersSubsections() {
        let parsed = MCPForeignConfigScanner.parseCodexTOML(#"""
        [mcp_servers.service]
        command = "service-mcp"

        [mcp_servers.service.env]
        FOO = "bar"

        [mcp_servers.service.headers]
        Authorization = "Bearer x"
        """#)

        XCTAssertEqual(parsed.first?.name, "service")
        XCTAssertEqual(parsed.first?.config.env?["FOO"], "bar")
        // Headers are ignored for stdio output, but parsing the subsection must not drop the server.
        XCTAssertEqual(parsed.first?.config.command, "service-mcp")
    }
}
