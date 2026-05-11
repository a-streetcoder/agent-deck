import XCTest
@testable import agent_deck

final class PiNativeBridgeExtensionSourceTests: XCTestCase {
    @MainActor
    func testOpenAIFastExtensionInjectsPriorityOnlyForEligibleConfiguredCodexModels() throws {
        let source = try String(contentsOf: PiNativeSubagentBridgeExtensions.openAIFastExtensionURL(), encoding: .utf8)

        XCTAssertTrue(source.contains(#"before_provider_request"#))
        XCTAssertTrue(source.contains(#"service_tier"#))
        XCTAssertTrue(source.contains(#""priority""#))
        XCTAssertTrue(source.contains(#""openai-codex""#))
        XCTAssertTrue(source.contains(#""openai-codex-responses""#))
        XCTAssertTrue(source.contains(#""gpt-5.4""#))
        XCTAssertTrue(source.contains(#""gpt-5.5""#))
        XCTAssertTrue(source.contains("AGENT_DECK_OPENAI_FAST_CONFIG"))
        XCTAssertTrue(source.contains("ctx.modelRegistry.isUsingOAuth(model)"))
        XCTAssertTrue(source.contains(#""service_tier" in event.payload"#))
    }

    @MainActor
    func testParentExtensionSourceRegistersEveryAppHandledBridgeTool() throws {
        let source = try String(contentsOf: PiNativeSubagentBridgeExtensions.parentExtensionURL(), encoding: .utf8)

        for toolName in [
            "managed_subagent",
            "managed_parallel",
            "list_supervisor_requests",
            "set_session_plan",
            "update_session_plan",
            "answer_supervisor_request"
        ] {
            XCTAssertTrue(source.contains(#"name: "\#(toolName)""#), "Missing registered parent bridge tool \(toolName)")
            XCTAssertTrue(source.contains(#"AGENT_DECK_BRIDGE \#(toolName)"#), "Missing editor bridge title for \(toolName)")
        }

        XCTAssertTrue(source.contains(#"bridge: "agent_deck_native_subagents""#))
        XCTAssertTrue(source.contains("additionalProperties: false"))
        XCTAssertTrue(source.contains("minItems: 1, maxItems: 8"))
        XCTAssertTrue(source.contains("minItems: 0, maxItems: 12"))
        XCTAssertTrue(source.contains("minItems: 1, maxItems: 12"))
    }

    @MainActor
    func testChildExtensionSourceRegistersContactSupervisorWithBlockingKindsAndEnvironmentIdentity() throws {
        let source = try String(contentsOf: PiNativeSubagentBridgeExtensions.childExtensionURL(), encoding: .utf8)

        XCTAssertTrue(source.contains(#"name: "contact_supervisor""#))
        XCTAssertTrue(source.contains("progress_update"))
        XCTAssertTrue(source.contains("need_decision"))
        XCTAssertTrue(source.contains("interview_request"))
        XCTAssertTrue(source.contains(#"AGENT_DECK_BRIDGE contact_supervisor"#))
        XCTAssertTrue(source.contains("AGENT_DECK_SUBAGENT_RUN_ID"))
        XCTAssertTrue(source.contains("AGENT_DECK_SUBAGENT_AGENT"))
        XCTAssertTrue(source.contains(#"bridge: "agent_deck_native_subagents""#))
        XCTAssertTrue(source.contains("additionalProperties: false"))
    }

    @MainActor
    func testSystemPromptAuditExtensionIsBundledAndReportsRuntimePrompt() throws {
        let source = try String(contentsOf: PiNativeSubagentBridgeExtensions.systemPromptAuditExtensionURL(), encoding: .utf8)

        XCTAssertTrue(source.contains(#"before_agent_start"#))
        XCTAssertTrue(source.contains(#"AGENT_DECK_BRIDGE system_prompt_audit"#))
        XCTAssertTrue(source.contains("agent_deck_system_prompt_audit"))
        XCTAssertTrue(source.contains("event.systemPrompt"))
        XCTAssertTrue(source.contains("ctx.getSystemPrompt()"))
        XCTAssertTrue(source.contains("AGENT_DECK_NATIVE_SUBAGENT"))
        XCTAssertTrue(source.contains("AGENT_DECK_SUBAGENT_RUN_ID"))
    }

    @MainActor
    func testAskUserExtensionIsBundledAsNativeAgentDeckBridge() throws {
        let source = try String(contentsOf: PiNativeSubagentBridgeExtensions.askUserExtensionURL(), encoding: .utf8)

        XCTAssertTrue(source.contains(#"name: "ask_user""#))
        XCTAssertTrue(source.contains(#"AGENT_DECK_BRIDGE ask_user"#))
        XCTAssertTrue(source.contains(#"bridge: "agent_deck_ask_user""#))
        XCTAssertTrue(source.contains("allowMultiple"))
        XCTAssertTrue(source.contains("allowFreeform"))
        XCTAssertTrue(source.contains("allowComment"))
        XCTAssertTrue(source.contains("User answered:"))
    }

    @MainActor
    func testWebAccessExtensionRegistersOnlyBundledExaTools() throws {
        let source = try String(contentsOf: PiNativeSubagentBridgeExtensions.webAccessExtensionURL(), encoding: .utf8)

        for toolName in ["web_search", "fetch_content", "get_search_content"] {
            XCTAssertTrue(source.contains(#"name: "\#(toolName)""#), "Missing registered web tool \(toolName)")
        }

        XCTAssertTrue(source.contains("https://api.exa.ai/"))
        XCTAssertTrue(source.contains("EXA_API_KEY"))
        XCTAssertTrue(source.contains(#""x-api-key""#))
        XCTAssertTrue(source.contains("contents: { text: true }"))
        XCTAssertTrue(source.contains("responseId"))
        XCTAssertFalse(source.contains(["code", "search"].joined(separator: "_")))
        XCTAssertFalse(source.contains(["PER", "PLEXITY"].joined()))
        XCTAssertFalse(source.contains(["GEM", "INI"].joined()))
    }
}
