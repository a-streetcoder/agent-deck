import XCTest
@testable import agent_deck

final class PiNativeBridgeExtensionSourceTests: XCTestCase {
    @MainActor
    func testOpenAIFastEligibilityIncludesEveryCodexModel() {
        XCTAssertTrue(PiNativeSubagentBridgeExtensions.isOpenAIFastEligibleModel(provider: "openai-codex"))
        XCTAssertFalse(PiNativeSubagentBridgeExtensions.isOpenAIFastEligibleModel(provider: "openai"))
        XCTAssertFalse(PiNativeSubagentBridgeExtensions.isOpenAIFastEligibleModel(provider: nil))
    }

    @MainActor
    func testOpenAIFastExtensionInjectsPriorityForEnabledOAuthCodexModels() throws {
        let source = try String(contentsOf: PiNativeSubagentBridgeExtensions.openAIFastExtensionURL(), encoding: .utf8)

        XCTAssertTrue(source.contains(#"before_provider_request"#))
        XCTAssertTrue(source.contains(#"service_tier"#))
        XCTAssertTrue(source.contains(#""priority""#))
        XCTAssertTrue(source.contains(#""openai-codex""#))
        XCTAssertTrue(source.contains(#""openai-codex-responses""#))
        XCTAssertFalse(source.contains("SUPPORTED_MODELS"))
        XCTAssertTrue(source.contains("AGENT_DECK_OPENAI_FAST_CONFIG"))
        XCTAssertTrue(source.contains("parsed?.enabled === true"))
        XCTAssertFalse(source.contains("enabledModels"))
        XCTAssertTrue(source.contains("ctx.modelRegistry.isUsingOAuth(model)"))
        XCTAssertTrue(source.contains("model.provider !== PROVIDER_ID"))
        XCTAssertTrue(source.contains("model.api !== API_ID"))
        XCTAssertTrue(source.contains("baseModelID(event.payload.model) !== baseModelID(ctx.model?.id)"))
        XCTAssertTrue(source.contains(#""service_tier" in event.payload"#))
    }

    func testOpenAIFastConfigEncodesBothGlobalStates() throws {
        for isEnabled in [false, true] {
            let data = try XCTUnwrap(PiNativeSubagentBridgeExtensions.openAIFastConfigData(isEnabled: isEnabled))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(payload["enabled"] as? Bool, isEnabled)
            XCTAssertEqual(payload.count, 1)
        }
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
        XCTAssertTrue(source.contains("Fresh Deck agents cannot see the parent conversation, context window, reasoning, tool results, user decisions, or prior-agent findings."))
        XCTAssertTrue(source.contains("Every fresh delegation must be self-contained"))
        XCTAssertTrue(source.contains("Restores only that child's session, never parent context."))
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
        XCTAssertTrue(source.contains("https://api.search.brave.com/res/v1/web/search"))
        XCTAssertTrue(source.contains("https://api.tavily.com/search"))
        XCTAssertTrue(source.contains("web-search.json"))
        XCTAssertTrue(source.contains("exaApiKey"))
        XCTAssertTrue(source.contains("braveApiKey"))
        XCTAssertTrue(source.contains("tavilyApiKey"))
        XCTAssertTrue(source.contains("EXA_API_KEY"))
        XCTAssertTrue(source.contains("BRAVE_API_KEY"))
        XCTAssertTrue(source.contains("TAVILY_API_KEY"))
        XCTAssertTrue(source.contains(#""x-api-key""#))
        XCTAssertTrue(source.contains("contents: { text: true }"))
        XCTAssertTrue(source.contains("responseId"))
        XCTAssertTrue(source.contains("resolveProvider"))
        XCTAssertFalse(source.contains(["code", "search"].joined(separator: "_")))
        XCTAssertFalse(source.contains(["PER", "PLEXITY"].joined()))
        XCTAssertFalse(source.contains(["GEM", "INI"].joined()))
    }

    func testWebSearchConfigURLMatchesPiWebAccessDefault() {
        let url = PiNativeSubagentBridgeExtensions.webSearchConfigURL()
        XCTAssertEqual(url.lastPathComponent, "web-search.json")
        XCTAssertTrue(url.path.contains("/.pi/") || url.path.hasSuffix("pi/web-search.json"))
    }

    func testIsWebSearchConfiguredReadsSupportedEnvKeys() {
        XCTAssertTrue(PiNativeSubagentBridgeExtensions.isWebSearchConfigured(environment: ["BRAVE_API_KEY": "x"]))
        XCTAssertTrue(PiNativeSubagentBridgeExtensions.isWebSearchConfigured(environment: ["TAVILY_API_KEY": "x"]))
        XCTAssertTrue(PiNativeSubagentBridgeExtensions.isWebSearchConfigured(environment: ["EXA_API_KEY": "x"]))
        // Empty env falls back to ~/.pi/web-search.json on this machine when present.
        let empty = PiNativeSubagentBridgeExtensions.isWebSearchConfigured(environment: [:])
        let fileHasKey = PiNativeSubagentBridgeExtensions.webSearchConfigHasSupportedCredential()
        XCTAssertEqual(empty, fileHasKey)
    }
}
