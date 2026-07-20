import XCTest
@testable import agent_deck

final class MCPConfigLoaderTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcp-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    private func write(_ json: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    func testProjectFilesOverrideHomeFilesPerServerName() throws {
        let home = tempRoot.appendingPathComponent("home", isDirectory: true)
        let project = tempRoot.appendingPathComponent("project", isDirectory: true)

        // Lowest precedence: ~/.config/mcp/mcp.json defines "shared" + "global-only".
        try write(#"""
        { "mcpServers": {
            "shared": { "command": "from-config" },
            "global-only": { "command": "keep-me" }
        } }
        """#, to: home.appendingPathComponent(".config/mcp/mcp.json"))

        // Highest precedence: <project>/.pi/mcp.json overrides "shared".
        try write(#"""
        { "mcpServers": {
            "shared": { "command": "from-project-pi" },
            "project-only": { "command": "added", "lifecycle": "eager" }
        } }
        """#, to: project.appendingPathComponent(".pi/mcp.json"))

        let loader = MCPConfigLoader(homeDirectory: home)
        let result = loader.load(projectRoot: project)
        let byName = Dictionary(uniqueKeysWithValues: result.servers.map { ($0.name, $0) })

        XCTAssertEqual(byName.count, 3)
        XCTAssertEqual(byName["shared"]?.config.command, "from-project-pi")
        XCTAssertEqual(byName["global-only"]?.config.command, "keep-me")
        XCTAssertEqual(byName["project-only"]?.config.command, "added")
        XCTAssertEqual(byName["project-only"]?.config.resolvedLifecycle, .eager)
        // Provenance points at the file the winning config came from.
        XCTAssertTrue(byName["shared"]?.sourcePath.hasSuffix(".pi/mcp.json") ?? false)
    }

    func testServersAreSortedCaseInsensitively() throws {
        let home = tempRoot.appendingPathComponent("home", isDirectory: true)
        try write(#"""
        { "mcpServers": { "Zeta": {"command": "z"}, "alpha": {"command": "a"}, "Beta": {"command": "b"} } }
        """#, to: home.appendingPathComponent(".pi/agent/mcp.json"))

        let loader = MCPConfigLoader(homeDirectory: home)
        let names = loader.load(projectRoot: nil).servers.map(\.name)
        XCTAssertEqual(names, ["alpha", "Beta", "Zeta"])
    }

    func testResolvedTransportInference() {
        var stdio = MCPServerConfig(); stdio.command = "npx"
        XCTAssertEqual(stdio.resolvedTransport, .stdio)
        var http = MCPServerConfig(); http.url = "https://example.com/mcp"
        XCTAssertEqual(http.resolvedTransport, .http)
        var explicit = MCPServerConfig(); explicit.url = "https://x"; explicit.transport = .sse
        XCTAssertEqual(explicit.resolvedTransport, .sse)
    }

    func testStaticAuthorizationDetectionIsCaseInsensitiveAndNonEmpty() {
        XCTAssertTrue(MCPServerConfig(headers: ["authorization": "Bearer TEST_TOKEN"]).hasStaticAuthorization)
        XCTAssertFalse(MCPServerConfig(headers: ["Authorization": "  "]).hasStaticAuthorization)
        XCTAssertFalse(MCPServerConfig(headers: ["X-Tenant": "example"]).hasStaticAuthorization)
        XCTAssertEqual(
            MCPServerConfig(headers: ["Authorization": "Bearer CANONICAL", "authorization": "Bearer DUPLICATE"]).staticAuthorizationValue,
            "Bearer CANONICAL"
        )
    }

    func testEffectiveEnvironmentInheritsAndConfiguredValuesWin() {
        let config = MCPServerConfig(env: ["AUTH_TOKEN": "TEST_TOKEN", "HOME": "/configured-home"])
        let environment = config.effectiveEnvironment(inherited: ["HOME": "/inherited-home", "PATH": "/usr/bin"])
        XCTAssertEqual(environment["AUTH_TOKEN"], "TEST_TOKEN")
        XCTAssertEqual(environment["HOME"], "/configured-home")
        XCTAssertEqual(environment["PATH"], "/usr/bin")
    }

    func testDiagnosticsRedactSecretLikeConfiguredValues() {
        let config = MCPServerConfig(
            env: ["TOKEN": "token-value", "SECRET": "secret-value", "PASSWORD": "password-value", "API_KEY": "key-value"],
            headers: ["Authorization": "Bearer TEST_TOKEN"]
        )
        let diagnostic = config.sanitizedDiagnostic("Bearer TEST_TOKEN token-value secret-value password-value key-value")
        XCTAssertFalse(diagnostic.contains("TEST_TOKEN"))
        XCTAssertFalse(diagnostic.contains("token-value"))
        XCTAssertFalse(diagnostic.contains("secret-value"))
        XCTAssertFalse(diagnostic.contains("password-value"))
        XCTAssertFalse(diagnostic.contains("key-value"))
        XCTAssertTrue(diagnostic.contains("<redacted>"))
    }

    func testMissingFilesYieldEmpty() {
        let loader = MCPConfigLoader(homeDirectory: tempRoot.appendingPathComponent("nope", isDirectory: true))
        XCTAssertTrue(loader.load(projectRoot: nil).servers.isEmpty)
    }

    // MARK: - Interpolation

    func testInterpolateBracedAndBareVariables() {
        let env = ["TOKEN": "secret", "DIR": "/tmp/x"]
        XCTAssertEqual(MCPConfigLoader.interpolate("${TOKEN}", environment: env), "secret")
        XCTAssertEqual(MCPConfigLoader.interpolate("$TOKEN", environment: env), "secret")
        XCTAssertEqual(MCPConfigLoader.interpolate("Bearer ${TOKEN}", environment: env), "Bearer secret")
        XCTAssertEqual(MCPConfigLoader.interpolate("$DIR/sub", environment: env), "/tmp/x/sub")
    }

    func testInterpolateUnknownVariableExpandsEmpty() {
        XCTAssertEqual(MCPConfigLoader.interpolate("a${MISSING}b", environment: [:]), "ab")
        XCTAssertEqual(MCPConfigLoader.interpolate("a$MISSING-b", environment: [:]), "a-b")
    }

    func testInterpolateLeadingTildeExpandsHome() {
        let home = URL(fileURLWithPath: "/Users/test")
        XCTAssertEqual(MCPConfigLoader.interpolate("~/dir", environment: [:], homeDirectory: home), "/Users/test/dir")
        XCTAssertEqual(MCPConfigLoader.interpolate("~", environment: [:], homeDirectory: home), "/Users/test")
        // A tilde mid-string is left untouched.
        XCTAssertEqual(MCPConfigLoader.interpolate("a/~/b", environment: [:], homeDirectory: home), "a/~/b")
    }

    func testInterpolateLoneDollarUntouched() {
        XCTAssertEqual(MCPConfigLoader.interpolate("cost is $5", environment: [:]), "cost is $5")
    }

}
