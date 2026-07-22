import XCTest
@testable import agent_deck

final class MCPXcodeBridgeLaunchPreflightTests: XCTestCase {
    func testDetectsOnlyDirectAndXcrunMCPBridgeInvocations() {
        XCTAssertTrue(MCPXcodeBridgeLaunchPreflight.isXcodeBridge(command: "mcpbridge", arguments: []))
        XCTAssertTrue(MCPXcodeBridgeLaunchPreflight.isXcodeBridge(command: "/usr/local/bin/mcpbridge", arguments: ["--stdio"]))
        XCTAssertTrue(MCPXcodeBridgeLaunchPreflight.isXcodeBridge(command: "xcrun", arguments: ["mcpbridge"]))
        XCTAssertTrue(MCPXcodeBridgeLaunchPreflight.isXcodeBridge(command: "/usr/bin/xcrun", arguments: ["--sdk", "macosx", "mcpbridge"]))
        XCTAssertFalse(MCPXcodeBridgeLaunchPreflight.isXcodeBridge(command: "node", arguments: ["mcpbridge"]))
        XCTAssertFalse(MCPXcodeBridgeLaunchPreflight.isXcodeBridge(command: "xcrun", arguments: ["--find", "mcpbridge"]))
    }

    func testUnavailableBridgeIsRejectedBeforeTransportSpawns() async {
        let transport = MCPStdioTransport(
            config: MCPServerConfig(command: "mcpbridge"),
            isXcodeRunning: { false }
        )

        do {
            try await transport.start(onLine: { _ in }, onClose: { _ in })
            XCTFail("Expected unavailable Xcode bridge to be rejected")
        } catch let error as MCPError {
            XCTAssertEqual(
                error,
                .transportFailed("Xcode MCP bridge requires a running Xcode instance. Open Xcode, or set MCP_XCODE_PID in the server environment.")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBridgeAllowsEffectiveEnvironmentPID() throws {
        XCTAssertNoThrow(
            try MCPXcodeBridgeLaunchPreflight.validate(
                command: "mcpbridge",
                arguments: [],
                environment: ["MCP_XCODE_PID": " 1234 "],
                isXcodeRunning: { false }
            )
        )
    }

    func testBridgeAllowsRunningXcode() throws {
        XCTAssertNoThrow(
            try MCPXcodeBridgeLaunchPreflight.validate(
                command: "xcrun",
                arguments: ["mcpbridge"],
                environment: [:],
                isXcodeRunning: { true }
            )
        )
    }

    func testUnrelatedCommandsRemainAllowedWithoutXcode() throws {
        XCTAssertNoThrow(
            try MCPXcodeBridgeLaunchPreflight.validate(
                command: "node",
                arguments: ["mcpbridge"],
                environment: [:],
                isXcodeRunning: { false }
            )
        )
    }
}
