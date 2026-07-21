import Foundation
import XCTest
@testable import agent_deck

@MainActor
final class AppTextSizeSettingsTests: XCTestCase {
    func testDefaultTextSizeIsStandard() {
        XCTAssertEqual(AppSettings().appTextSize, .standard)
    }

    func testLegacySettingsDecodeToStandardTextSize() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.appTextSize, .standard)
    }

    func testUnknownTextSizeFallsBackToStandard() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"appTextSize":"futureSize"}"#.utf8))
        XCTAssertEqual(settings.appTextSize, .standard)
    }

    func testTextSizeRoundTripsThroughSettingsPersistencePayload() throws {
        var settings = AppSettings()
        settings.appTextSize = .extraLarge

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.appTextSize, .extraLarge)
    }

    func testControllerUpdatesTextSizeSetting() {
        let controller = AppSettingsController()
        let original = controller.settings.appTextSize
        defer { _ = controller.setAppTextSize(original) }

        XCTAssertTrue(controller.setAppTextSize(.large))
        XCTAssertEqual(controller.settings.appTextSize, .large)
        XCTAssertFalse(controller.setAppTextSize(.large))
    }
}
