import XCTest
@testable import pi_manager

final class PiNativeBridgeExtensionSourceTests: XCTestCase {
    func testParentExtensionSourceRegistersEveryAppHandledBridgeTool() throws {
        let source = try String(contentsOf: PiNativeSubagentBridgeExtensions.parentExtensionURL(), encoding: .utf8)

        for toolName in [
            "managed_subagent",
            "managed_chain",
            "managed_parallel",
            "list_supervisor_requests",
            "set_session_plan",
            "update_session_plan",
            "answer_supervisor_request"
        ] {
            XCTAssertTrue(source.contains(#"name: "\#(toolName)""#), "Missing registered parent bridge tool \(toolName)")
            XCTAssertTrue(source.contains(#"PI_MANAGER_BRIDGE \#(toolName)"#), "Missing editor bridge title for \(toolName)")
        }

        XCTAssertTrue(source.contains(#"bridge: "pi_manager_native_subagents""#))
        XCTAssertTrue(source.contains("additionalProperties: false"))
        XCTAssertTrue(source.contains("minItems: 1, maxItems: 8"))
        XCTAssertTrue(source.contains("minItems: 0, maxItems: 12"))
        XCTAssertTrue(source.contains("minItems: 1, maxItems: 12"))
    }

    func testChildExtensionSourceRegistersContactSupervisorWithBlockingKindsAndEnvironmentIdentity() throws {
        let source = try String(contentsOf: PiNativeSubagentBridgeExtensions.childExtensionURL(), encoding: .utf8)

        XCTAssertTrue(source.contains(#"name: "contact_supervisor""#))
        XCTAssertTrue(source.contains("progress_update"))
        XCTAssertTrue(source.contains("need_decision"))
        XCTAssertTrue(source.contains("interview_request"))
        XCTAssertTrue(source.contains(#"PI_MANAGER_BRIDGE contact_supervisor"#))
        XCTAssertTrue(source.contains("PI_MANAGER_SUBAGENT_RUN_ID"))
        XCTAssertTrue(source.contains("PI_MANAGER_SUBAGENT_AGENT"))
        XCTAssertTrue(source.contains(#"bridge: "pi_manager_native_subagents""#))
        XCTAssertTrue(source.contains("additionalProperties: false"))
    }
}
