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

    func testAvailablePluginUsesStableIDReadOnlyProvenanceAndPolicy() {
        let entries = CodexComputerUseMCPIntegration.merge(configured: [], discovery: .init(resources: [resource()], diagnostics: []))
        let entry = try! XCTUnwrap(entries.first)
        XCTAssertEqual(entry.name, "codex-computer-use")
        XCTAssertEqual(entry.config.command, "/transient/root/helper")
        XCTAssertEqual(entry.toolPolicy, .computerUseObservationOnly)
        XCTAssertFalse(entry.sourcePath.isEmpty)
        XCTAssertTrue(entry.isAvailable)
        XCTAssertFalse(entry.provenance == .config)
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
