import XCTest
@testable import agent_deck

@MainActor
final class QuestionRailScrollLandingTests: XCTestCase {
    func testQuestionRailShowsScrollableOverflowWhenStackDoesNotFit() {
        let policy = QuestionRailVisibilityPolicy()
        XCTAssertTrue(policy.shouldShow(questionCount: 18, evenStackedHeight: 520, railHeight: 328))
    }

    func testQuestionRailShowsOverflowEvenWhenManyQuestionsExceedTallWindow() {
        let policy = QuestionRailVisibilityPolicy()
        XCTAssertTrue(policy.shouldShow(questionCount: 40, evenStackedHeight: 1_120, railHeight: 668))
    }

    func testQuestionRailShowsOnlyWithMultipleQuestions() {
        let policy = QuestionRailVisibilityPolicy()
        XCTAssertFalse(policy.shouldShow(questionCount: 1, evenStackedHeight: 22, railHeight: 268))
        XCTAssertTrue(policy.shouldShow(questionCount: 3, evenStackedHeight: 82, railHeight: 268))
    }

    func testActiveQuestionUsesLandingOffsetFromViewportTop() {
        let resolver = QuestionRailActiveQuestionResolver(landingOffset: 12, visibleHeight: 500)
        let questions: [(id: String, minY: CGFloat)] = [
            ("q1", 100),
            ("q2", 360),
            ("q3", 900)
        ]

        XCTAssertEqual(resolver.activeID(questions: questions, viewportY: 347, documentHeight: 2_000), "q1")
        XCTAssertEqual(resolver.activeID(questions: questions, viewportY: 348, documentHeight: 2_000), "q2")
    }

    func testActiveQuestionClampsToLastAtDocumentBottom() {
        let resolver = QuestionRailActiveQuestionResolver(landingOffset: 12, visibleHeight: 500)
        let questions: [(id: String, minY: CGFloat)] = [
            ("q1", 100),
            ("q2", 360),
            ("q3", 900)
        ]

        XCTAssertEqual(resolver.activeID(questions: questions, viewportY: 1_500, documentHeight: 2_000), "q3")
    }

    func testLandingResolverNormalStackedRailConvergesFirstSelection() {
        let resolver = QuestionRailScrollLandingResolver(landingOffset: 18, visibleHeight: 600)
        let finalY = runLanding(resolver: resolver, rowMinYMeasurements: [1_240])
        XCTAssertEqual(finalY, 1_222, accuracy: 0.001)
        XCTAssertNil(resolver.needsCorrection(currentY: finalY, rowMinY: 1_240, documentHeight: 4_000))
    }

    func testLandingResolverSlidingRailWithManyMessagesKeepsCorrectingUntilStable() {
        let resolver = QuestionRailScrollLandingResolver(landingOffset: 18, visibleHeight: 420)
        let finalY = runLanding(
            resolver: resolver,
            rowMinYMeasurements: [12_000, 12_180, 12_245, 12_252]
        )
        XCTAssertEqual(finalY, 12_234, accuracy: 0.001)
        XCTAssertNil(resolver.needsCorrection(currentY: finalY, rowMinY: 12_252, documentHeight: 20_000))
    }

    func testLandingResolverClampsToDocumentBottom() {
        let resolver = QuestionRailScrollLandingResolver(landingOffset: 18, visibleHeight: 500)
        XCTAssertEqual(resolver.targetY(rowMinY: 4_900, documentHeight: 5_000), 4_500)
    }

    func testKeyboardNavigatorMovesToAdjacentQuestion() {
        let navigator = QuestionRailKeyboardNavigator()
        let ids = ["q1", "q2", "q3"]

        XCTAssertEqual(navigator.targetID(questionIDs: ids, activeID: "q2", direction: .previous), "q1")
        XCTAssertEqual(navigator.targetID(questionIDs: ids, activeID: "q2", direction: .next), "q3")
    }

    func testKeyboardNavigatorConsumesEdgesWithoutWrapping() {
        let navigator = QuestionRailKeyboardNavigator()
        let ids = ["q1", "q2", "q3"]

        XCTAssertNil(navigator.targetID(questionIDs: ids, activeID: "q1", direction: .previous))
        XCTAssertNil(navigator.targetID(questionIDs: ids, activeID: "q3", direction: .next))
    }

    func testKeyboardNavigatorChoosesDirectionalEndWhenNoActiveQuestion() {
        let navigator = QuestionRailKeyboardNavigator()
        let ids = ["q1", "q2", "q3"]

        XCTAssertEqual(navigator.targetID(questionIDs: ids, activeID: nil, direction: .previous), "q3")
        XCTAssertEqual(navigator.targetID(questionIDs: ids, activeID: nil, direction: .next), "q1")
        XCTAssertNil(navigator.targetID(questionIDs: ["q1"], activeID: nil, direction: .next))
    }

    private func runLanding(
        resolver: QuestionRailScrollLandingResolver,
        rowMinYMeasurements: [CGFloat],
        documentHeight: CGFloat = 20_000
    ) -> CGFloat {
        precondition(!rowMinYMeasurements.isEmpty)
        var y = resolver.targetY(rowMinY: rowMinYMeasurements[0], documentHeight: documentHeight)
        var correction = 0
        for rowMinY in rowMinYMeasurements.dropFirst() {
            guard correction < resolver.maxCorrections,
                  let correctedY = resolver.needsCorrection(currentY: y, rowMinY: rowMinY, documentHeight: documentHeight) else {
                break
            }
            y = correctedY
            correction += 1
        }
        return y
    }
}
