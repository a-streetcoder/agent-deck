import XCTest
@testable import agent_deck

@MainActor
final class EphemeralSlashCommandTests: XCTestCase {
    func testOmitsPureExtensionSlash() {
        XCTAssertTrue(EphemeralSlashCommand.shouldOmitFromTranscript(
            text: "/blackhole-memory status",
            hasAttachments: false
        ))
        XCTAssertTrue(EphemeralSlashCommand.shouldOmitFromTranscript(
            text: "/ocr\n/blackhole",
            hasAttachments: false
        ))
    }

    func testKeepsSkillsFreeTextAndAttachments() {
        XCTAssertFalse(EphemeralSlashCommand.shouldOmitFromTranscript(
            text: "/skill:foo do it",
            hasAttachments: false
        ))
        XCTAssertFalse(EphemeralSlashCommand.shouldOmitFromTranscript(
            text: "hello /not-a-command",
            hasAttachments: false
        ))
        XCTAssertFalse(EphemeralSlashCommand.shouldOmitFromTranscript(
            text: "plain text",
            hasAttachments: false
        ))
        XCTAssertFalse(EphemeralSlashCommand.shouldOmitFromTranscript(
            text: "/blackhole",
            hasAttachments: true
        ))
    }

    func testEmptyIsNotEphemeral() {
        XCTAssertFalse(EphemeralSlashCommand.shouldOmitFromTranscript(text: "   ", hasAttachments: false))
        XCTAssertFalse(EphemeralSlashCommand.shouldOmitFromTranscript(text: "", hasAttachments: false))
    }
}
