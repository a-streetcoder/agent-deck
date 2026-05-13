import XCTest
@testable import agent_deck

final class PiAgentPasteMarkerCodecTests: XCTestCase {
    @MainActor
    func testCollapsesAndExpandsLongMultiLinePaste() {
        let pastedText = (1...11).map { "line \($0)" }.joined(separator: "\n")
        let marker = PiAgentPasteMarkerCodec.marker(id: 1, text: pastedText)
        let attachment = PiAgentPasteAttachment(id: 1, marker: marker, text: pastedText)

        XCTAssertTrue(PiAgentPasteMarkerCodec.shouldCollapse(pastedText))
        XCTAssertEqual(marker, "[paste #1 +11 lines]")
        XCTAssertEqual(
            PiAgentPasteMarkerCodec.expandMarkers(in: "before \(marker) after", attachments: [attachment]),
            "before \(pastedText) after"
        )
    }

    @MainActor
    func testCollapsesAndExpandsLongSingleLinePaste() {
        let pastedText = String(repeating: "x", count: 1001)
        let marker = PiAgentPasteMarkerCodec.marker(id: 2, text: pastedText)
        let attachment = PiAgentPasteAttachment(id: 2, marker: marker, text: pastedText)

        XCTAssertTrue(PiAgentPasteMarkerCodec.shouldCollapse(pastedText))
        XCTAssertEqual(marker, "[paste #2 1001 chars]")
        XCTAssertEqual(PiAgentPasteMarkerCodec.expandMarkers(in: marker, attachments: [attachment]), pastedText)
    }

    @MainActor
    func testDoesNotCollapseSmallPasteAndNormalizesLineEndings() {
        let normalized = PiAgentPasteMarkerCodec.normalizedText(from: "a\r\nb\rc\td")

        XCTAssertEqual(normalized, "a\nb\nc    d")
        XCTAssertFalse(PiAgentPasteMarkerCodec.shouldCollapse("short\ntext"))
    }

    @MainActor
    func testInactiveDeletedPasteAttachmentsAreIgnored() {
        let pastedText = String(repeating: "x", count: 1001)
        let marker = PiAgentPasteMarkerCodec.marker(id: 1, text: pastedText)
        let attachment = PiAgentPasteAttachment(id: 1, marker: marker, text: pastedText)

        XCTAssertEqual(PiAgentPasteMarkerCodec.activeAttachments(in: "marker deleted", attachments: [attachment]), [])
        XCTAssertEqual(PiAgentPasteMarkerCodec.expandMarkers(in: "marker deleted", attachments: [attachment]), "marker deleted")
    }
}
