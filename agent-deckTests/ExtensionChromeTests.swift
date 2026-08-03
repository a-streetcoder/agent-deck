import XCTest
@testable import agent_deck

@MainActor
final class ExtensionChromeTests: XCTestCase {
    func testSetStatusUpsertClearAndIdempotent() {
        var chrome = PiAgentExtensionChrome()
        XCTAssertTrue(chrome.applySetStatus(key: "pi-ocr", text: "OCR: mineru"))
        XCTAssertEqual(chrome.statuses["pi-ocr"], "OCR: mineru")
        XCTAssertFalse(chrome.applySetStatus(key: "pi-ocr", text: "OCR: mineru"))
        XCTAssertTrue(chrome.applySetStatus(key: "pi-ocr", text: "OCR: ollama"))
        XCTAssertEqual(chrome.statuses["pi-ocr"], "OCR: ollama")
        XCTAssertTrue(chrome.applySetStatus(key: "pi-ocr", text: "  "))
        XCTAssertTrue(chrome.isEmpty)
        XCTAssertFalse(chrome.applySetStatus(key: "  ", text: "x"))
    }

    func testSetWidgetAndStatusItemsSorted() {
        var chrome = PiAgentExtensionChrome()
        XCTAssertTrue(chrome.applySetWidget(key: "b", lines: [" line2 ", "", "line1"]))
        XCTAssertTrue(chrome.applySetStatus(key: "z", text: "Z"))
        XCTAssertTrue(chrome.applySetStatus(key: "a", text: "A"))
        XCTAssertEqual(chrome.statusItems.map(\.key), ["a", "z"])
        XCTAssertEqual(chrome.widgetItems.first?.lines, ["line2", "line1"])
        XCTAssertTrue(chrome.applySetWidget(key: "b", lines: ["  ", ""]))
        XCTAssertTrue(chrome.widgets.isEmpty)
    }
}
