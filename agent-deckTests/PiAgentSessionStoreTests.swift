import XCTest
@testable import agent_deck

@MainActor
final class PiAgentSessionStoreTests: XCTestCase {
    func testSessionPlanSetAndUpdateAreStableInPlace() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Smoke", project: try PiTestSupport.makeProject(), repository: nil)

        let plan = store.setSessionPlan(sessionID: session.id, items: [
            .init(id: "inspect", title: "Inspect smoke", status: .inProgress),
            .init(id: "delegate", title: "Run native subagent smoke", status: .todo),
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

    func testCreatedSessionSelectionPersistsAcrossReload() throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        let session = firstStore.createSession(kind: .project, title: "Selected", project: try PiTestSupport.makeProject(), repository: nil)
        firstStore.flushForTesting()

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)

        XCTAssertEqual(reloadedStore.selectedSessionID, session.id)
        XCTAssertEqual(reloadedStore.selectedSession?.id, session.id)
    }

    func testLazyTranscriptLoadingReloadsEvictedTranscriptFromDisk() throws {
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
        reloadedStore.configureTranscriptMemory(lazyLoadingEnabled: true, cacheLimit: 1)
        reloadedStore.select(second.id)

        XCTAssertEqual(reloadedStore.transcript(for: first.id).map(\.text), ["first transcript"])
        XCTAssertEqual(reloadedStore.transcript(for: second.id).map(\.text), ["second transcript"])

        reloadedStore.configureTranscriptMemory(lazyLoadingEnabled: false, cacheLimit: 1)
        XCTAssertEqual(reloadedStore.transcriptsBySessionID[first.id]?.map(\.text), ["first transcript"])
        XCTAssertEqual(reloadedStore.transcriptsBySessionID[second.id]?.map(\.text), ["second transcript"])
    }

    func testReloadWithNilPersistedSelectionSelectsFirstSession() throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        let session = firstStore.createSession(kind: .project, title: "Selected", project: try PiTestSupport.makeProject(), repository: nil)
        firstStore.flushForTesting()
        try rewritePersistedSelection(in: fileURL, selectedSessionID: NSNull())

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)

        XCTAssertEqual(reloadedStore.selectedSessionID, session.id)
        XCTAssertEqual(reloadedStore.selectedSession?.id, session.id)
    }

    func testReloadWithInvalidPersistedSelectionSelectsFirstSession() throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        let session = firstStore.createSession(kind: .project, title: "Selected", project: try PiTestSupport.makeProject(), repository: nil)
        firstStore.flushForTesting()
        try rewritePersistedSelection(in: fileURL, selectedSessionID: UUID().uuidString)

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)

        XCTAssertEqual(reloadedStore.selectedSessionID, session.id)
        XCTAssertEqual(reloadedStore.selectedSession?.id, session.id)
    }

    func testAvailableModelSeedingBatchesSessionUpdatesWithoutOverwritingExistingByDefault() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let project = try PiTestSupport.makeProject()
        let first = store.createSession(kind: .project, title: "First", project: project, repository: nil)
        let second = store.createSession(kind: .project, title: "Second", project: project, repository: nil)
        let original = PiAgentModelOption(provider: "openai", id: "old", name: nil, contextWindow: nil, maxOutput: nil, supportsThinking: false, supportedThinkingLevels: nil, supportsImages: false)
        let seeded = PiAgentModelOption(provider: "anthropic", id: "new", name: nil, contextWindow: nil, maxOutput: nil, supportsThinking: true, supportedThinkingLevels: ["low"], supportsImages: true)

        store.updateAvailableModelsForSessions([first.id], options: [original], overwriteExisting: true)
        store.updateAvailableModelsForSessions(options: [seeded])

        XCTAssertEqual(store.sessions.first(where: { $0.id == first.id })?.availableModels?.map(\.id), ["old"])
        XCTAssertEqual(store.sessions.first(where: { $0.id == second.id })?.availableModels?.map(\.id), ["new"])

        store.updateAvailableModelsForSessions(options: [seeded], overwriteExisting: true)
        XCTAssertEqual(store.sessions.first(where: { $0.id == first.id })?.availableModels?.map(\.id), ["new"])
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
