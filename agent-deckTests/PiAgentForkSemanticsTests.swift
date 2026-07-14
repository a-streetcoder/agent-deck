import XCTest
@testable import agent_deck

/// Pins the fork/re-run store semantics: a normal fork parks the forked user
/// message in the new session's composer; a re-run fork records the same
/// fork-origin metadata but leaves the composer empty (the runner sends the
/// message itself). Both preserve the parent linkage used by the recap card.
@MainActor
final class PiAgentForkSemanticsTests: XCTestCase {

    private func makeParent(in store: PiAgentSessionStore) throws -> PiAgentSessionRecord {
        let parent = store.createSession(kind: .project, title: "Parent", project: try PiTestSupport.makeProject(), repository: nil)
        store.append(.init(sessionID: parent.id, role: .user, title: "You", text: "original question"))
        store.append(.init(sessionID: parent.id, role: .assistant, title: "Coding Agent", text: "original answer"))
        return parent
    }

    func testForkSeedsComposerAndRecordsOrigin() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let parent = try makeParent(in: store)

        let fork = store.forkSession(
            from: parent,
            newPiSessionFile: "/tmp/fork.jsonl",
            newPiSessionId: "pi-fork-1",
            composerSeed: "original question"
        )

        XCTAssertEqual(store.composerDraft(for: fork.id).text, "original question",
            "a normal fork must park the message in the composer for review")
        XCTAssertEqual(fork.forkedFromSessionID, parent.id)
        XCTAssertEqual(fork.forkedFromUserMessageText, "original question")
        XCTAssertEqual(fork.piSessionFile, "/tmp/fork.jsonl")
        XCTAssertEqual(store.selectedSessionID, fork.id, "fork auto-selects the new session")
        XCTAssertEqual(fork.projectPath, parent.projectPath)
        XCTAssertEqual(fork.worktreePath, parent.worktreePath)
    }

    /// The fork-origin snapshot must reflect exactly the inherited history:
    /// turns at/after the forked message never carry over and must not appear.
    func testForkSnapshotCutsAtForkedMessage() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let parent = try makeParent(in: store)
        let forkedAt = PiAgentTranscriptEntry(sessionID: parent.id, role: .user, title: "You", text: "second question")
        store.append(forkedAt)
        store.append(.init(sessionID: parent.id, role: .assistant, title: "Coding Agent", text: "second answer"))

        let fork = store.forkSession(
            from: parent,
            newPiSessionFile: "/tmp/fork-cut.jsonl",
            newPiSessionId: "pi-fork-3",
            composerSeed: "second question",
            cutBeforeEntryID: forkedAt.id
        )

        let snapshot = try XCTUnwrap(fork.forkedFromTranscriptSnapshot)
        XCTAssertTrue(snapshot.contains("original question"))
        XCTAssertTrue(snapshot.contains("original answer"))
        XCTAssertFalse(snapshot.contains("second question"),
            "the forked-at message was never part of the inherited history")
        XCTAssertFalse(snapshot.contains("second answer"),
            "turns after the fork point must not appear in the recap snapshot")
    }

    /// Re-run is in-place: the SAME session rewinds to just before the chosen
    /// user message and rebinds to the branched Pi session file — no new
    /// session record, the tail entries removed from the visible transcript.
    func testRerunRewindsSessionInPlace() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let parent = try makeParent(in: store)
        let rerunTarget = PiAgentTranscriptEntry(sessionID: parent.id, role: .user, title: "You", text: "second question")
        store.append(rerunTarget)
        store.append(.init(sessionID: parent.id, role: .assistant, title: "Coding Agent", text: "second answer"))
        let sessionCount = store.sessions.count

        store.rewindSession(
            parent.id,
            fromEntryID: rerunTarget.id,
            newPiSessionFile: "/tmp/rerun-branch.jsonl",
            newPiSessionId: "pi-branch-1"
        )

        XCTAssertEqual(store.sessions.count, sessionCount, "re-run must not create a new session")
        let entries = store.transcript(for: parent.id)
        XCTAssertEqual(entries.map(\.text), ["original question", "original answer"],
            "the chosen message and everything after it must be dropped")
        let rebound = store.sessions.first(where: { $0.id == parent.id })
        XCTAssertEqual(rebound?.piSessionFile, "/tmp/rerun-branch.jsonl",
            "the same record rebinds to the branched Pi session file")
        XCTAssertEqual(rebound?.piSessionId, "pi-branch-1")
        XCTAssertEqual(store.composerDraft(for: parent.id).text, "",
            "re-run sends the message itself; nothing parked in the composer")
    }

    func testForkSeedUsesCanonicalAttachmentSyntaxNotTranscriptProjection() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let parent = try makeParent(in: store)
        let canonical = "<file name=\"shot.png\"></file>"
        let entry = PiAgentTranscriptEntry(sessionID: parent.id, role: .user, title: "You", text: canonical)
        store.append(entry)

        let fork = store.forkSession(
            from: parent,
            newPiSessionFile: "/tmp/fork-attachment.jsonl",
            newPiSessionId: "pi-fork-attachment",
            composerSeed: entry.text
        )

        XCTAssertEqual(store.composerDraft(for: fork.id).text, canonical)
        XCTAssertEqual(fork.forkedFromUserMessageText, canonical)
    }

    /// Re-run resends the original attachments — they must round-trip through
    /// the transcript entry's rawJSON exactly as the runner recorded them.
    func testUserEntryAttachmentsRoundTrip() throws {
        let payload: [String: Any] = [
            "images": [[
                "id": UUID().uuidString,
                "name": "shot.png",
                "mimeType": "image/png",
                "data": "aGVsbG8=",
                "sizeBytes": 5
            ]]
        ]
        let rawJSON = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        let entry = PiAgentTranscriptEntry(sessionID: UUID(), role: .user, title: "You", text: "see image", rawJSON: rawJSON)

        let decoded = entry.userAttachments
        XCTAssertEqual(decoded?.images?.count, 1)
        XCTAssertEqual(decoded?.images?.first?.name, "shot.png")
        XCTAssertEqual(decoded?.images?.first?.data, "aGVsbG8=")

        let nonUser = PiAgentTranscriptEntry(sessionID: UUID(), role: .status, title: "Status", text: "x", rawJSON: rawJSON)
        XCTAssertNil(nonUser.userAttachments, "attachment decode is user-entries only")
    }
}
