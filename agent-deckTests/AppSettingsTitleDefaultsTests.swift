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
}
