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
}
