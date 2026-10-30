import AppKit
import XCTest
@testable import agent_deck

@MainActor
final class ComposerInputMethodTests: XCTestCase {
    func testMarkedTextKeepsCompositionKeysAwayFromComposerActions() {
        for (characters, keyCode) in [("\r", UInt16(36)), ("\t", 48), ("\u{1b}", 53), ("\u{f700}", 126), ("\u{f701}", 125)] {
            let view = DropSafeNSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
            let handler = KeyHandler()
            handler.active = true
            view.keyHandler = handler
            view.setMarkedText("hello", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(view.hasMarkedText())

            view.keyDown(with: keyEvent(characters, keyCode: keyCode))

            XCTAssertEqual(handler.actionCount, 0, "Composer intercepted key code \(keyCode) during composition")
        }
    }

    func testReturnSendsAfterCompositionAndAcceptsActiveSuggestion() {
        let view = DropSafeNSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        let handler = KeyHandler()
        view.keyHandler = handler
        view.setMarkedText("hello", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()

        view.keyDown(with: keyEvent("\r", keyCode: 36))
        XCTAssertEqual(handler.sendCount, 1)

        handler.active = true
        view.keyDown(with: keyEvent("\r", keyCode: 36))
        XCTAssertEqual(handler.acceptCount, 1)
        XCTAssertEqual(handler.sendCount, 1)
    }

    private func keyEvent(_ characters: String, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }
}

@MainActor
private final class KeyHandler: DropSafeNSTextViewKeyHandler {
    var active = false
    var sendCount = 0
    var acceptCount = 0
    var actionCount = 0

    func send() { sendCount += 1; actionCount += 1 }
    func clear() { actionCount += 1 }
    func suggestionsActive() -> Bool { active }
    func moveSuggestionHighlight(by delta: Int) { actionCount += 1 }
    func acceptSuggestionHighlight() -> Bool { acceptCount += 1; actionCount += 1; return true }
    func dismissSuggestions() { actionCount += 1 }
    func startDictation(in textView: NSTextView) { actionCount += 1 }
}
