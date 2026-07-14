import XCTest
@testable import agent_deck

final class MCPBridgeExtensionContractTests: XCTestCase {
    @MainActor
    func testGeneratedMCPBridgeDecodesVersionedMixedContentEnvelope() throws {
        let source = try String(contentsOf: PiNativeSubagentBridgeExtensions.mcpExtensionURL(), encoding: .utf8)

        XCTAssertTrue(source.contains("type MCPBridgeContent"))
        XCTAssertTrue(source.contains("version: 1"))
        XCTAssertTrue(source.contains("parseMCPBridgeCallResult"))
        XCTAssertTrue(source.contains("action === \"call\""))
        XCTAssertTrue(source.contains("content: callResult.content"))
        XCTAssertTrue(source.contains("details: {"))
        XCTAssertTrue(source.contains("isError: callResult.isError"))
        XCTAssertTrue(source.contains("type: \"image\"; data: string; mimeType: string"))
        XCTAssertTrue(source.contains("result || \"MCP returned no output.\""), "Plain-string fallback remains available for list/search/describe and older bridge responses.")
    }
}
