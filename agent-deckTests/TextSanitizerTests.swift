import XCTest
@testable import agent_deck

@MainActor
final class TextSanitizerTests: XCTestCase {
    func testStripAnsiTruecolorAndOrphanSgr() {
        let esc = "\u{001B}"
        let raw = "\(esc)[38;2;138;190;183mThinking:\(esc)[39m hello"
        XCTAssertEqual(TextSanitizer.sanitizeThinking(raw), "hello")
        XCTAssertEqual(TextSanitizer.stripAnsi("[38;2;138;190;183mhi[39m"), "hi")
    }

    func testSanitizeThinkingRemovesDecorativeLabels() {
        XCTAssertEqual(TextSanitizer.sanitizeThinking("Thinking: plan"), "plan")
        XCTAssertEqual(TextSanitizer.sanitizeThinking("思考：步骤"), "步骤")
        XCTAssertEqual(TextSanitizer.sanitizeThinking("thinking:  x"), "x")
    }

    func testSanitizeAnswerKeepsMarkdownStripsAnsiOnly() {
        let esc = "\u{001B}"
        let md = "## Title\n\n- item"
        XCTAssertEqual(TextSanitizer.sanitizeAnswer(md), md)
        XCTAssertEqual(TextSanitizer.sanitizeAnswer("\(esc)[0m**bold**"), "**bold**")
    }
}
