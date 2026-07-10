import XCTest
@testable import agent_deck

@MainActor
final class AutoPerfJourneySelectionTests: XCTestCase {
    func testNamedJourneysAreMutuallyExclusive() {
        XCTAssertEqual(
            AutoPerfJourneySelection.resolve(journey: "scroll", legacySidebarOnly: false),
            .init(scroll: true, stream: false, sidebar: false)
        )
        XCTAssertEqual(
            AutoPerfJourneySelection.resolve(journey: "stream", legacySidebarOnly: false),
            .init(scroll: false, stream: true, sidebar: false)
        )
        XCTAssertEqual(
            AutoPerfJourneySelection.resolve(journey: "sidebar", legacySidebarOnly: false),
            .init(scroll: false, stream: false, sidebar: true)
        )
    }

    func testLegacySidebarOnlyAndDefaultSelectionRemainSupported() {
        XCTAssertEqual(
            AutoPerfJourneySelection.resolve(journey: nil, legacySidebarOnly: true),
            .init(scroll: false, stream: false, sidebar: true)
        )
        XCTAssertEqual(
            AutoPerfJourneySelection.resolve(journey: nil, legacySidebarOnly: false),
            .init(scroll: true, stream: true, sidebar: true)
        )
    }
}
