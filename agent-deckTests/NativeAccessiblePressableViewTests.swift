import AppKit
import XCTest
@testable import agent_deck

private final class FlippedHitTestContainer: NSView {
    override var isFlipped: Bool { true }
}

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

    func testHitTestConvertsNonzeroSuperviewCoordinatesToLocalBounds() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let child = NativeAccessiblePressableView(frame: NSRect(x: 40, y: 50, width: 80, height: 60))
        child.pressAction = {}
        parent.addSubview(child)

        XCTAssertTrue(parent.hitTest(NSPoint(x: 55, y: 67)) === child)
        XCTAssertTrue(parent.hitTest(NSPoint(x: 125, y: 111)) === parent)
    }

    func testHitTestWithoutSuperviewUsesLocalCoordinates() {
        let view = NativeAccessiblePressableView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        view.pressAction = {}

        XCTAssertTrue(view.hitTest(NSPoint(x: 10, y: 10)) === view)
        XCTAssertNil(view.hitTest(NSPoint(x: 30, y: 10)))
    }

    func testHitTestConvertsCoordinatesThroughFlippedSuperview() {
        let parent = FlippedHitTestContainer(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let child = NativeAccessiblePressableView(frame: NSRect(x: 40, y: 50, width: 80, height: 60))
        child.pressAction = {}
        parent.addSubview(child)

        XCTAssertTrue(parent.hitTest(NSPoint(x: 55, y: 100)) === child)
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
