import XCTest
@testable import agent_deck

@MainActor
final class TranscriptMeasuredHeightResolverTests: XCTestCase {
    func testFreshStreamingMeasurementCanShrinkFromInitialEstimate() {
        // An initial tiled estimate is not a real measurement and therefore is
        // intentionally absent from the resolver's clamp input.
        let initialTiledEstimate: CGFloat = 180
        let resolved = TranscriptMeasuredHeightResolver.resolvedHeight(
            84,
            priorMeasuredHeight: nil,
            isStreaming: true
        )

        XCTAssertEqual(resolved, 84)
        XCTAssertLessThan(resolved, initialTiledEstimate)
    }

    func testStreamingMeasurementCannotShrinkBelowPriorMeasurement() {
        let resolved = TranscriptMeasuredHeightResolver.resolvedHeight(
            84,
            priorMeasuredHeight: 120,
            isStreaming: true
        )

        XCTAssertEqual(resolved, 120)
    }

    func testStreamingMeasurementCanGrowBeyondPriorMeasurement() {
        let resolved = TranscriptMeasuredHeightResolver.resolvedHeight(
            156,
            priorMeasuredHeight: 120,
            isStreaming: true
        )

        XCTAssertEqual(resolved, 156)
    }

    func testNonStreamingMeasurementCanShrinkBelowPriorMeasurement() {
        let resolved = TranscriptMeasuredHeightResolver.resolvedHeight(
            84,
            priorMeasuredHeight: 120,
            isStreaming: false
        )

        XCTAssertEqual(resolved, 84)
    }
}
