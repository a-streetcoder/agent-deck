import XCTest
@testable import agent_deck

@MainActor
final class PiAgentSessionStoreTests: XCTestCase {
    func testSessionPlanSetAndUpdateAreStableInPlace() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Smoke", project: try PiTestSupport.makeProject(), repository: nil)

        let plan = store.setSessionPlan(sessionID: session.id, items: [
            .init(id: "inspect", title: "Inspect smoke", status: .inProgress),
            .init(id: "delegate", title: "Run Deck agent smoke", status: .todo),
            .init(id: "finish", title: "Summarize result", status: .todo)
        ])

        XCTAssertEqual(plan.items.map(\.id), ["inspect", "delegate", "finish"])
        XCTAssertEqual(plan.items.map(\.status), [.inProgress, .todo, .todo])

        let updated = store.updateSessionPlan(sessionID: session.id, updates: [
            .init(id: "inspect", title: nil, status: .done),
            .init(id: "delegate", title: nil, status: .inProgress)
        ])

        XCTAssertEqual(updated?.items.map(\.id), ["inspect", "delegate", "finish"])
        XCTAssertEqual(updated?.items.map(\.status), [.done, .inProgress, .todo])
        XCTAssertEqual(store.sessionPlan(for: session.id)?.items.count, 3)
    }

    func testCreatedSessionSelectionPersistsAcrossReload() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        let session = firstStore.createSession(kind: .project, title: "Selected", project: try PiTestSupport.makeProject(), repository: nil)
        firstStore.flushForTesting()

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)
        await reloadedStore.waitForLoadForTesting()

        XCTAssertEqual(reloadedStore.selectedSessionID, session.id)
        XCTAssertEqual(reloadedStore.selectedSession?.id, session.id)
    }

    func testNoProjectCodingAgentSessionPersistsAsNoProject() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        let session = firstStore.createNoProjectCodingAgentSession(title: "No Project")
        firstStore.flushForTesting()

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)
        await reloadedStore.waitForLoadForTesting()

        let reloaded = try XCTUnwrap(reloadedStore.sessions.first(where: { $0.id == session.id }))
        XCTAssertTrue(reloaded.isNoProject)
        XCTAssertNil(reloaded.projectPathForProjectFeatures)
        XCTAssertEqual(reloaded.projectNameForDisplay, PiAgentSessionRecord.noProjectDisplayName)
        XCTAssertFalse(reloaded.subagentsEnabled)
    }

    func testLazyTranscriptLoadingReloadsEvictedTranscriptFromDisk() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        firstStore.configureTranscriptMemory(lazyLoadingEnabled: true, cacheLimit: 1)
        let project = try PiTestSupport.makeProject()
        let first = firstStore.createSession(kind: .project, title: "First", project: project, repository: nil)
        firstStore.append(.init(sessionID: first.id, role: .user, title: "User", text: "first transcript"))
        let second = firstStore.createSession(kind: .project, title: "Second", project: project, repository: nil)
        firstStore.append(.init(sessionID: second.id, role: .user, title: "User", text: "second transcript"))
        firstStore.flushForTesting()

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)
        await reloadedStore.waitForLoadForTesting()
        reloadedStore.configureTranscriptMemory(lazyLoadingEnabled: true, cacheLimit: 1)
        reloadedStore.select(second.id)

        XCTAssertEqual(reloadedStore.transcript(for: first.id).map(\.text), ["first transcript"])
        XCTAssertEqual(reloadedStore.transcript(for: second.id).map(\.text), ["second transcript"])

        reloadedStore.configureTranscriptMemory(lazyLoadingEnabled: false, cacheLimit: 1)
        XCTAssertEqual(reloadedStore.transcriptsBySessionID[first.id]?.map(\.text), ["first transcript"])
        XCTAssertEqual(reloadedStore.transcriptsBySessionID[second.id]?.map(\.text), ["second transcript"])
    }

    func testLazyTranscriptLoadingStartsEmptyAndLoadsSelectedTranscriptAsynchronously() async throws {
        // Lazy transcript loading is always on; `reloadedStore` below relies on that default.
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        firstStore.configureTranscriptMemory(lazyLoadingEnabled: true, cacheLimit: 1)
        let session = firstStore.createSession(kind: .project, title: "Async", project: try PiTestSupport.makeProject(), repository: nil)
        firstStore.append(.init(sessionID: session.id, role: .user, title: "User", text: "async transcript"))
        firstStore.flushForTesting()

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)
        await reloadedStore.waitForLoadForTesting()

        XCTAssertNil(reloadedStore.transcriptsBySessionID[session.id])
        XCTAssertEqual(reloadedStore.selectedTranscript, [])

        reloadedStore.requestSelectedTranscriptLoad()

        let ok = await PiTestSupport.waitUntilAsync {
            reloadedStore.selectedTranscript.map(\.text) == ["async transcript"]
        }
        XCTAssertTrue(ok)
    }

    func testTranscriptForCacheUpdateReturnsWarmTranscriptSynchronously() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Warm", project: try PiTestSupport.makeProject(), repository: nil)
        store.append(.init(sessionID: session.id, role: .user, title: "User", text: "warm transcript"))

        XCTAssertNotNil(store.transcriptsBySessionID[session.id])
        XCTAssertEqual(store.transcriptForCacheUpdate(session.id).map(\.text), ["warm transcript"])
    }

    func testTranscriptForCacheUpdateDecodesSmallTranscriptSynchronously() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        let session = firstStore.createSession(kind: .project, title: "Small", project: try PiTestSupport.makeProject(), repository: nil)
        firstStore.append(.init(sessionID: session.id, role: .user, title: "User", text: "small transcript"))
        firstStore.flushForTesting()

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)
        await reloadedStore.waitForLoadForTesting()
        XCTAssertNil(reloadedStore.transcriptsBySessionID[session.id])

        // A small transcript decodes synchronously straight into memory — no deferral.
        let entries = reloadedStore.transcriptForCacheUpdate(session.id)
        XCTAssertEqual(entries.map(\.text), ["small transcript"])
        XCTAssertNotNil(reloadedStore.transcriptsBySessionID[session.id])
    }

    func testTranscriptForCacheUpdateDefersLargeTranscriptToBackgroundLoader() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        let session = firstStore.createSession(kind: .project, title: "Large", project: try PiTestSupport.makeProject(), repository: nil)
        let largeText = String(repeating: "A", count: 8_000)
        for index in 0..<80 {
            firstStore.append(.init(sessionID: session.id, role: .user, title: "Entry \(index)", text: largeText))
        }
        firstStore.flushForTesting()

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)
        await reloadedStore.waitForLoadForTesting()
        XCTAssertNil(reloadedStore.transcriptsBySessionID[session.id])

        // A large transcript (>256 KB) must not decode on the main thread: an empty
        // snapshot is returned now and the background loader is in flight.
        let entries = reloadedStore.transcriptForCacheUpdate(session.id)
        XCTAssertEqual(entries, [])
        XCTAssertNil(reloadedStore.transcriptsBySessionID[session.id])
        XCTAssertTrue(reloadedStore.transcriptLoadingSessionIDs.contains(session.id))

        let ok = await PiTestSupport.waitUntilAsync {
            reloadedStore.transcriptsBySessionID[session.id]?.count == 80
        }
        XCTAssertTrue(ok)
        XCTAssertFalse(reloadedStore.transcriptLoadingSessionIDs.contains(session.id))
    }

    func testTranscriptForCacheUpdateReturnsFullTranscriptWhenLazyLoadingDisabled() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        let session = firstStore.createSession(kind: .project, title: "NonLazy", project: try PiTestSupport.makeProject(), repository: nil)
        let largeText = String(repeating: "A", count: 8_000)
        for index in 0..<80 {
            firstStore.append(.init(sessionID: session.id, role: .user, title: "Entry \(index)", text: largeText))
        }
        firstStore.flushForTesting()

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)
        await reloadedStore.waitForLoadForTesting()
        reloadedStore.configureTranscriptMemory(lazyLoadingEnabled: false, cacheLimit: 10)

        // With lazy loading off, even a large transcript resolves synchronously and
        // in full — never an empty deferral snapshot.
        let entries = reloadedStore.transcriptForCacheUpdate(session.id)
        XCTAssertEqual(entries.count, 80)
        XCTAssertNotNil(reloadedStore.transcriptsBySessionID[session.id])
    }

    func testReloadWithNilPersistedSelectionSelectsFirstSession() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        let session = firstStore.createSession(kind: .project, title: "Selected", project: try PiTestSupport.makeProject(), repository: nil)
        firstStore.flushForTesting()
        try rewritePersistedSelection(in: fileURL, selectedSessionID: NSNull())

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)
        await reloadedStore.waitForLoadForTesting()

        XCTAssertEqual(reloadedStore.selectedSessionID, session.id)
        XCTAssertEqual(reloadedStore.selectedSession?.id, session.id)
    }

    func testReloadWithInvalidPersistedSelectionSelectsFirstSession() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        let session = firstStore.createSession(kind: .project, title: "Selected", project: try PiTestSupport.makeProject(), repository: nil)
        firstStore.flushForTesting()
        try rewritePersistedSelection(in: fileURL, selectedSessionID: UUID().uuidString)

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)
        await reloadedStore.waitForLoadForTesting()

        XCTAssertEqual(reloadedStore.selectedSessionID, session.id)
        XCTAssertEqual(reloadedStore.selectedSession?.id, session.id)
    }

    func testSupervisorRequestAnswerAndCancelStateTransitions() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Supervisor", project: try PiTestSupport.makeProject(), repository: nil)
        let runID = UUID()
        let request = PiSubagentSupervisorRequest(
            id: "request-1",
            bridgeRequestID: "bridge-1",
            runID: runID,
            parentSessionID: session.id,
            childID: nil,
            kind: .needDecision,
            title: "Decision",
            message: "Choose.",
            status: .pending,
            response: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        store.upsertSupervisorRequest(request)
        store.updateSupervisorRequest(request.id, parentSessionID: session.id) { item in
            item.status = .answered
            item.response = "Use worktree."
        }

        XCTAssertEqual(store.supervisorRequests(for: session.id).first?.status, .answered)
        XCTAssertEqual(store.supervisorRequests(for: session.id).first?.response, "Use worktree.")

        store.updateSupervisorRequest(request.id, parentSessionID: session.id) { item in
            item.status = .cancelled
        }

        XCTAssertEqual(store.supervisorRequests(for: session.id).first?.status, .cancelled)
    }

    private func rewritePersistedSelection(in fileURL: URL, selectedSessionID: Any) throws {
        let data = try Data(contentsOf: fileURL)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Expected persisted Pi Agent state dictionary.")
            return
        }
        object["selectedSessionID"] = selectedSessionID
        let rewritten = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try rewritten.write(to: fileURL, options: .atomic)
    }
}
