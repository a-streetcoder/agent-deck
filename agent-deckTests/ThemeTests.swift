import Foundation
import XCTest
@testable import agent_deck

@MainActor
final class ThemeTests: XCTestCase {

    // MARK: ThemeColor

    func testThemeColorComponentInitNormalizesTo0to1() {
        let color = ThemeColor(255, 128, 0)
        XCTAssertEqual(color.red, 1.0, accuracy: 0.0001)
        XCTAssertEqual(color.green, 128.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(color.blue, 0.0, accuracy: 0.0001)
    }

    func testThemeColorHexString() {
        XCTAssertEqual(ThemeColor(255, 128, 0).hexString, "#FF8000")
        XCTAssertEqual(ThemeColor(0, 0, 0).hexString, "#000000")
        XCTAssertEqual(ThemeColor(255, 255, 255).hexString, "#FFFFFF")
    }

    func testThemeColorRoundTripsThroughSwiftUIColor() {
        let original = ThemeColor(120, 60, 200)
        let roundTripped = ThemeColor(color: original.color)
        XCTAssertEqual(roundTripped.red, original.red, accuracy: 0.02)
        XCTAssertEqual(roundTripped.green, original.green, accuracy: 0.02)
        XCTAssertEqual(roundTripped.blue, original.blue, accuracy: 0.02)
    }

    func testThemeColorCodableRoundTrip() throws {
        let original = ThemeColor(red: 0.25, green: 0.5, blue: 0.75)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ThemeColor.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testLightenedAndDarkenedMixMath() {
        let mid = ThemeColor(red: 0.4, green: 0.4, blue: 0.4)
        let lighter = mid.lightened(by: 0.5)
        XCTAssertEqual(lighter.red, 0.7, accuracy: 0.0001) // 0.4 + (1 - 0.4) * 0.5
        let darker = mid.darkened(by: 0.5)
        XCTAssertEqual(darker.red, 0.2, accuracy: 0.0001)  // 0.4 * (1 - 0.5)
    }

    // MARK: Theme

    func testThemeCodableRoundTrip() throws {
        let original = Theme.ember
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Theme.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testThemeDecodeFillsMissingTokensFromDefault() throws {
        // A theme stored by an older build that only knew the accent token.
        let json = """
        {"id":"\(UUID().uuidString)","name":"Partial","isBuiltIn":false,\
        "accent":{"red":0.5,"green":0.5,"blue":0.5}}
        """
        let decoded = try JSONDecoder().decode(Theme.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.name, "Partial")
        XCTAssertEqual(decoded.thinking, Theme.defaultTheme.thinking)
        XCTAssertEqual(decoded.tool, Theme.defaultTheme.tool)
        XCTAssertEqual(decoded.diffAdded, Theme.defaultTheme.diffAdded)
    }

    func testBuiltInThemesHaveStableUniqueIdentifiers() {
        let ids = Theme.builtInThemes.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Built-in theme UUIDs must be unique")
        XCTAssertTrue(Theme.builtInThemes.allSatisfy(\.isBuiltIn))
        XCTAssertEqual(Theme.builtInThemes.first?.id, Theme.defaultTheme.id)
    }

    func testDerivedAccentShadesAreOrderedByLuminance() {
        func luminance(_ c: ThemeColor) -> Double { c.red + c.green + c.blue }
        let theme = Theme.defaultTheme
        XCTAssertGreaterThan(luminance(theme.accentBright), luminance(theme.accent))
        XCTAssertLessThan(luminance(theme.accentDeep), luminance(theme.accent))
        XCTAssertLessThan(luminance(theme.accentShadow), luminance(theme.accentDeep))
    }

    // MARK: AppSettings migration

    func testAppSettingsDecodesLegacyJSONWithoutThemeKeys() throws {
        // Settings stored before themes existed have neither key.
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.selectedThemeID, Theme.defaultTheme.id)
        XCTAssertTrue(settings.customThemes.isEmpty)
    }

    func testAppSettingsRoundTripsCustomThemes() throws {
        var settings = AppSettings()
        let custom = Theme(
            name: "Mine",
            isBuiltIn: false,
            accent: ThemeColor(10, 20, 30),
            assistant: ThemeColor(40, 50, 60),
            thinking: ThemeColor(70, 80, 90),
            tool: ThemeColor(100, 110, 120),
            error: ThemeColor(130, 140, 150),
            stderr: ThemeColor(160, 170, 180),
            diffAdded: ThemeColor(190, 200, 210)
        )
        settings.customThemes = [custom]
        settings.selectedThemeID = custom.id

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)

        XCTAssertEqual(decoded.customThemes, [custom])
        XCTAssertEqual(decoded.selectedThemeID, custom.id)
    }
}
