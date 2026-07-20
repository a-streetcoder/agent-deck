import XCTest
@testable import agent_deck

final class AnalyticsTests: XCTestCase {
    func testAppOpenedRequiresAnUntrackedProcessAndConfiguredToken() {
        XCTAssertTrue(
            Analytics.shouldTrackAppOpened(
                projectToken: "phc_agent_deck",
                environment: [:],
                hasTrackedAppOpened: false
            )
        )
        XCTAssertFalse(
            Analytics.shouldTrackAppOpened(
                projectToken: "   ",
                environment: [:],
                hasTrackedAppOpened: false
            )
        )
        XCTAssertFalse(
            Analytics.shouldTrackAppOpened(
                projectToken: "phc_agent_deck",
                environment: [:],
                hasTrackedAppOpened: true
            )
        )
    }

    func testAppOpenedIsDisabledForTestPreviewAndPerformanceRuns() {
        for environment in [
            ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"],
            ["XCTestBundlePath": "/tmp/agent-deckTests.xctest"],
            ["XCODE_RUNNING_FOR_PREVIEWS": "1"],
            ["AGENTDECK_AUTOPERF": "1"],
            ["AGENTDECK_BENCHMARK": "1"]
        ] {
            XCTAssertFalse(
                Analytics.shouldTrackAppOpened(
                    projectToken: "phc_agent_deck",
                    environment: environment,
                    hasTrackedAppOpened: false
                )
            )
        }
    }
}
