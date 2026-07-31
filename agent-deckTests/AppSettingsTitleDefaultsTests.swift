import Foundation
import XCTest
@testable import agent_deck

@MainActor
final class AppSettingsTitleDefaultsTests: XCTestCase {

    func testTitleGenerationIsOnByDefault() {
        let settings = AppSettings()
        XCTAssertTrue(settings.autoGeneratePiAgentSessionTitles)
        XCTAssertTrue(settings.autoUpdatePiAgentSessionTitles)
    }

    func testTitleModelDefaultsToNoExplicitPick() {
        // nil means "follow the Pi default model"; the Apple Foundation model
        // must not be pre-selected even on machines where it is available.
        let settings = AppSettings()
        XCTAssertNil(settings.piAgentTitleGenerationModelIdentifier)
    }

    func testDecodingEmptyPayloadKeepsTitleDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(settings.autoGeneratePiAgentSessionTitles)
        XCTAssertTrue(settings.autoUpdatePiAgentSessionTitles)
        XCTAssertNil(settings.piAgentTitleGenerationModelIdentifier)
    }

    func testDecodingPreservesStoredTitleChoices() throws {
        let payload = """
        {"autoGeneratePiAgentSessionTitles": false, "piAgentTitleGenerationModelIdentifier": "some/model"}
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(payload.utf8))
        XCTAssertFalse(settings.autoGeneratePiAgentSessionTitles)
        XCTAssertEqual(settings.piAgentTitleGenerationModelIdentifier, "some/model")
    }

    func testOpenAIFastDefaultsOffAndMigratesAnyLegacyEnabledModel() throws {
        XCTAssertFalse(AppSettings().openAIFastEnabled)

        let migrated = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"openAIFastModeModelIdentifiers":["openai-codex/gpt-5"]}"#.utf8)
        )
        XCTAssertTrue(migrated.openAIFastEnabled)
    }

    func testStoredOpenAIFastValueWinsOverLegacyModelSetting() throws {
        let settings = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"openAIFastEnabled":false,"openAIFastModeModelIdentifiers":["openai-codex/gpt-5"]}"#.utf8)
        )
        XCTAssertFalse(settings.openAIFastEnabled)
    }

    func testOpenAIFastEncodingUsesOnlyGlobalPreference() throws {
        var settings = AppSettings()
        settings.openAIFastEnabled = true

        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        XCTAssertEqual(payload["openAIFastEnabled"] as? Bool, true)
        XCTAssertNil(payload["openAIFastModeModelIdentifiers"])
    }

    func testHelperRuntimeModelArgumentAvoidsForcedOffOnReasoningModels() {
        let reasoning = AvailableModel(
            provider: "grok-cli",
            model: "grok-4.5",
            contextWindow: "500K",
            maxOutput: "30K",
            supportsThinking: true,
            supportsImages: true,
            // Baseline catalog lists off first — helpers must not pick it.
            supportedThinkingLevels: ["off", "minimal", "low", "medium", "high"]
        )
        XCTAssertEqual(
            PiSessionTitleGenerationService.helperRuntimeModelArgument(for: reasoning),
            "grok-4.5:minimal"
        )

        let nonThinking = AvailableModel(
            provider: "grok-cli",
            model: "grok-composer-2.5-fast",
            contextWindow: "200K",
            maxOutput: "30K",
            supportsThinking: false,
            supportsImages: false,
            supportedThinkingLevels: ["off"]
        )
        XCTAssertEqual(
            PiSessionTitleGenerationService.helperRuntimeModelArgument(for: nonThinking),
            "grok-composer-2.5-fast"
        )

        let offOnly = AvailableModel(
            provider: "example",
            model: "r1",
            contextWindow: "128K",
            maxOutput: "8K",
            supportsThinking: true,
            supportsImages: false,
            supportedThinkingLevels: ["off", "none"]
        )
        XCTAssertEqual(
            PiSessionTitleGenerationService.helperRuntimeModelArgument(for: offOnly),
            "r1"
        )
    }

    func testProvisionalAutoTitleIncludesDraftAndAgentChatPrefixes() throws {
        var draft = try PiTestSupport.makeParentSession()
        draft.title = "Draft · pi-deck"
        draft.isTitleUserEdited = false
        XCTAssertTrue(draft.isProvisionalAutoTitle)

        var agentChat = draft
        agentChat.title = "Chat · Explore"
        XCTAssertTrue(agentChat.isProvisionalAutoTitle)

        var generated = draft
        generated.title = "Fix session title generation"
        XCTAssertFalse(generated.isProvisionalAutoTitle)

        var userEdited = draft
        userEdited.title = "Draft · pi-deck"
        userEdited.isTitleUserEdited = true
        XCTAssertFalse(userEdited.isProvisionalAutoTitle)
    }
}
