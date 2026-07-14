import XCTest
@testable import agent_deck

final class CodexComputerUseMCPIntegrationTests: XCTestCase {
    private func resource() -> CodexPluginMCPDiscovery.Resource {
        CodexPluginMCPDiscovery.Resource(
            pluginID: CodexPluginMCPDiscovery.computerUsePluginID,
            serverName: "computer-use",
            version: "1.2.3",
            provenance: .init(marketplace: "openai-bundled", sourceType: "local", source: "/transient/root"),
            config: MCPServerConfig(command: "/transient/root/helper", args: ["mcp"]),
            sourcePath: "/transient/root/.mcp.json"
        )
    }

    private func broker() -> CodexComputerUseBrokerDiscovery.Result {
        .available(.init(
            nodeURL: URL(fileURLWithPath: "/runtime/node"),
            serverScriptURL: URL(fileURLWithPath: "/broker/dist/mcp-server.js"),
            packageRootURL: URL(fileURLWithPath: "/broker"),
            stateRootURL: URL(fileURLWithPath: "/state")
        ))
    }

    func testAvailablePluginUsesStableIDBrokerAndNoPermissionsPolicy() {
        let entries = CodexComputerUseMCPIntegration.merge(
            configured: [], discovery: .init(resources: [resource()], diagnostics: []), brokerDiscovery: broker()
        )
        let entry = try! XCTUnwrap(entries.first)
        XCTAssertEqual(entry.name, "codex-computer-use")
        XCTAssertEqual(entry.config.command, "/runtime/node")
        XCTAssertEqual(entry.config.args, ["/broker/dist/mcp-server.js"])
        XCTAssertEqual(entry.config.cwd, "/broker")
        XCTAssertEqual(entry.config.env?["CODEX_COMPUTER_USE_HOME"], "/state")
        XCTAssertEqual(entry.config.resolvedLifecycle, .lazy)
        XCTAssertEqual(entry.toolPolicy, .computerUseNoPermissions)
        XCTAssertEqual(entry.sourcePath, "/broker/dist/mcp-server.js")
        XCTAssertTrue(entry.isAvailable)
        XCTAssertFalse(entry.provenance == .config)
    }

    func testAvailablePluginWithoutBrokerRetainsStableUnavailableEntry() {
        let entry = CodexComputerUseMCPIntegration.merge(
            configured: [], discovery: .init(resources: [resource()], diagnostics: []),
            brokerDiscovery: .unavailable("install exact broker")
        ).first!
        XCTAssertEqual(entry.name, "codex-computer-use")
        XCTAssertEqual(entry.toolPolicy, .computerUseNoPermissions)
        XCTAssertFalse(entry.isAvailable)
        XCTAssertEqual(entry.availabilityDiagnostic, "install exact broker")
        XCTAssertNil(entry.config.command)
    }

    func testExplicitConfigWinsCollisionWithoutChangingIdentity() {
        let configured = MCPServerEntry(name: "codex-computer-use", config: MCPServerConfig(command: "user-helper"), sourcePath: "/user/mcp.json")
        let entry = CodexComputerUseMCPIntegration.merge(configured: [configured], discovery: .init(resources: [resource()], diagnostics: [])).first!
        XCTAssertEqual(entry.config.command, "user-helper")
        XCTAssertEqual(entry.provenance, .config)
        XCTAssertNotNil(entry.diagnostic)
    }

    func testUnavailablePluginRetainsStableAssignableIDWithoutStalePath() {
        let entry = CodexComputerUseMCPIntegration.merge(configured: [], discovery: .init(resources: [], diagnostics: [.pluginDisabled])).first!
        XCTAssertEqual(entry.name, "codex-computer-use")
        XCTAssertFalse(entry.isAvailable)
        XCTAssertTrue(entry.sourcePath.isEmpty)
        XCTAssertNil(entry.config.command)
    }
}
