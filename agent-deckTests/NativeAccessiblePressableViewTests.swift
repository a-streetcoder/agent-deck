import AppKit
import XCTest
@testable import agent_deck

@MainActor
final class NativeAccessiblePressableViewTests: XCTestCase {
    func testVoiceOverAndKeyboardPressUseSingleCallback() {
        let view = NativeAccessiblePressableView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        var activations = 0
        view.pressAction = { activations += 1 }

        XCTAssertTrue(view.acceptsFirstResponder)
        XCTAssertEqual(view.accessibilityRole(), .button)
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertEqual(activations, 1)

        let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: 0, context: nil, characters: " ",
                                     charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        view.keyDown(with: space)
        XCTAssertEqual(activations, 2)

        let click = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 10, y: 10),
                                       modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseUp(with: click)
        XCTAssertEqual(activations, 3)
    }

    func testStaticTextRoleIsNotFocusableOrPressable() {
        let view = NativeAccessiblePressableView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        var activations = 0
        view.pressAction = { activations += 1 }
        view.pressRole = .staticText

        XCTAssertFalse(view.acceptsFirstResponder)
        XCTAssertEqual(view.accessibilityRole(), .staticText)
        XCTAssertFalse(view.accessibilityPerformPress())
        let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: 0, context: nil, characters: " ",
                                     charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        view.keyDown(with: space)
        let click = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 10, y: 10),
                                       modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseUp(with: click)
        XCTAssertEqual(activations, 0)
    }
}
