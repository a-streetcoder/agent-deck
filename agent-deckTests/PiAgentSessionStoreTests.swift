import XCTest
@testable import agent_deck

@MainActor
final class PiAgentSessionStoreTests: XCTestCase {
    func testSelectingSessionDiscardsItsPendingBackgroundRevisionWithoutSubsequentMutation() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let background = store.createSession(kind: .project, title: "Background", project: try PiTestSupport.makeProject(), repository: nil)
        _ = store.createSession(kind: .project, title: "Selected", project: try PiTestSupport.makeProject(), repository: nil)

        store.append(.init(sessionID: background.id, role: .assistant, title: "Assistant", text: "background"))
        XCTAssertEqual(store.transcriptRevisionsBySessionID[background.id], 0)

        store.select(background.id)
        store.flushPendingTranscriptRevisionsForTesting()
        XCTAssertEqual(store.transcriptRevisionsBySessionID[background.id], 0)
    }

    func testDeletingSelectedSessionDiscardsPendingFallbackRevisionWithoutSubsequentMutation() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let fallback = store.createSession(kind: .project, title: "Fallback", project: try PiTestSupport.makeProject(), repository: nil)
        let selected = store.createSession(kind: .project, title: "Selected", project: try PiTestSupport.makeProject(), repository: nil)

        store.append(.init(sessionID: fallback.id, role: .assistant, title: "Assistant", text: "background"))
        XCTAssertEqual(store.transcriptRevisionsBySessionID[fallback.id], 0)

        store.deleteSessions([selected.id], fallbackSelectionID: fallback.id)
        XCTAssertEqual(store.selectedSessionID, fallback.id)
        store.flushPendingTranscriptRevisionsForTesting()
        XCTAssertEqual(store.transcriptRevisionsBySessionID[fallback.id], 0)
    }

    func testOnlyExplicitPacedSelectedUpsertsPublishImmediately() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Selected", project: try PiTestSupport.makeProject(), repository: nil)

        store.upsert(
            .init(sessionID: session.id, role: .assistant, title: "Assistant", text: "paced"),
            persist: false,
            revisionPolicy: .immediateForSelectedSession
        )
        XCTAssertEqual(store.transcriptRevisionsBySessionID[session.id], 1)

        // A selected tool update retains normal coalescing and cannot introduce a
        // second high-frequency revision source alongside the runner's text cadence.
        store.upsert(.init(sessionID: session.id, role: .tool, title: "Tool", text: "update"), persist: false)
        XCTAssertEqual(store.transcriptRevisionsBySessionID[session.id], 1)
        store.flushPendingTranscriptRevisionsForTesting()
        XCTAssertEqual(store.transcriptRevisionsBySessionID[session.id], 2)
    }

    func testBackgroundTranscriptRevisionRemainsCoalesced() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let background = store.createSession(kind: .project, title: "Background", project: try PiTestSupport.makeProject(), repository: nil)
        _ = store.createSession(kind: .project, title: "Selected", project: try PiTestSupport.makeProject(), repository: nil)

        store.append(.init(sessionID: background.id, role: .assistant, title: "Assistant", text: "background"))
        XCTAssertEqual(store.transcriptRevisionsBySessionID[background.id], 0)

        store.flushPendingTranscriptRevisionsForTesting()
        XCTAssertEqual(store.transcriptRevisionsBySessionID[background.id], 1)
    }

    func testForkCopiesParentLaunchOverridesButAgentChatForkDoesNot() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let parent = store.createSession(kind: .project, title: "Parent", project: try PiTestSupport.makeProject(), repository: nil)
        store.updateSession(parent.id) {
            $0.agentLaunchOverrides = ["explorer": .init(model: .value("openai/gpt-5.4-mini"), thinking: .piDefault)]
        }
        let current = try XCTUnwrap(store.sessions.first(where: { $0.id == parent.id }))
        let fork = store.forkSession(from: current, newPiSessionFile: "/tmp/fork.jsonl", newPiSessionId: nil, composerSeed: "Continue")
        XCTAssertEqual(fork.agentLaunchOverrides, current.agentLaunchOverrides)

        let agentFork = store.forkSessionAsAgentChat(
            from: current,
            agent: PiTestSupport.makeAgent(name: "explorer"),
            composerSeed: "Continue"
        )
        XCTAssertNil(agentFork.agentLaunchOverrides)
    }

    func testPinMutationChangesOnlyPinStateAndSessionListRevision() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Pinned", project: try PiTestSupport.makeProject(), repository: nil)
        let originalUpdatedAt = session.updatedAt
        let pinnedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let initialRevision = store.sessionListRevision

        store.setSessionPinned(session.id, pinned: true, at: pinnedAt)
        XCTAssertEqual(store.sessions.first(where: { $0.id == session.id })?.pinnedAt, pinnedAt)
        XCTAssertEqual(store.sessions.first(where: { $0.id == session.id })?.updatedAt, originalUpdatedAt)
        XCTAssertEqual(store.sessionListRevision, initialRevision + 1)

        store.setSessionPinned(session.id, pinned: true, at: pinnedAt.addingTimeInterval(60))
        XCTAssertEqual(store.sessions.first(where: { $0.id == session.id })?.pinnedAt, pinnedAt)
        XCTAssertEqual(store.sessionListRevision, initialRevision + 1)

        store.setSessionPinned(session.id, pinned: false)
        XCTAssertNil(store.sessions.first(where: { $0.id == session.id })?.pinnedAt)
        XCTAssertEqual(store.sessions.first(where: { $0.id == session.id })?.updatedAt, originalUpdatedAt)
        XCTAssertEqual(store.sessionListRevision, initialRevision + 2)
    }

    func testPinnedAtPersistsAcrossReload() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        let session = firstStore.createSession(kind: .project, title: "Pinned", project: try PiTestSupport.makeProject(), repository: nil)
        let pinnedAt = Date(timeIntervalSince1970: 1_700_000_000)
        firstStore.setSessionPinned(session.id, pinned: true, at: pinnedAt)
        firstStore.flushForTesting()

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)
        await reloadedStore.waitForLoadForTesting()
        XCTAssertEqual(reloadedStore.sessions.first(where: { $0.id == session.id })?.pinnedAt, pinnedAt)
    }

    func testImmediateQuitDuringInitialLoadCannotOverwritePersistedSessionsWithEmptyPlaceholder() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        let session = firstStore.createSession(kind: .project, title: "Survives", project: try PiTestSupport.makeProject(), repository: nil)
        firstStore.flushForTesting()

        let reopeningStore = PiAgentSessionStore(fileURL: fileURL)
        reopeningStore.flushForTesting()
        await reopeningStore.waitForLoadForTesting()
        reopeningStore.flushForTesting()

        let verifiedStore = PiAgentSessionStore(fileURL: fileURL)
        await verifiedStore.waitForLoadForTesting()
        XCTAssertEqual(verifiedStore.sessions.map(\.id), [session.id])
    }

    func testCorruptPrimaryIndexRecoversLastKnownGoodBackup() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        let session = firstStore.createSession(kind: .project, title: "Recoverable", project: try PiTestSupport.makeProject(), repository: nil)
        firstStore.flushForTesting()
        firstStore.updateSession(session.id) { $0.needsAttention = true }
        firstStore.flushForTesting()

        let backupURL = fileURL.deletingPathExtension().appendingPathExtension("backup.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        try Data("interrupted write".utf8).write(to: fileURL, options: .atomic)

        let recoveredStore = PiAgentSessionStore(fileURL: fileURL)
        await recoveredStore.waitForLoadForTesting()

        XCTAssertEqual(recoveredStore.sessions.map(\.id), [session.id])
        XCTAssertTrue(recoveredStore.lastError?.contains("last-known-good backup") == true)
    }

    func testSessionRecordWithoutPinnedAtDecodesAsUnpinned() throws {
        let session = try PiTestSupport.makeParentSession()
        let encoded = try JSONEncoder().encode(session)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "pinnedAt")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(PiAgentSessionRecord.self, from: legacyData)
        XCTAssertNil(decoded.pinnedAt)
    }

    func testLaunchOverridesPersistAcrossReload() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        let session = firstStore.createSession(kind: .project, title: "Overrides", project: try PiTestSupport.makeProject(), repository: nil)
        firstStore.updateSession(session.id) {
            $0.agentLaunchOverrides = ["explorer": .init(model: .piDefault, thinking: .value("high"))]
        }
        firstStore.flushForTesting()

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)
        await reloadedStore.waitForLoadForTesting()
        XCTAssertEqual(
            reloadedStore.sessions.first(where: { $0.id == session.id })?.agentLaunchOverrides,
            ["explorer": .init(model: .piDefault, thinking: .value("high"))]
        )
    }

    func testLastUserMessageTimestampTracksUserEntriesOnly() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Activity", project: try PiTestSupport.makeProject(), repository: nil)
        let assistantDate = Date(timeIntervalSince1970: 100)
        let olderUserDate = Date(timeIntervalSince1970: 200)
        let newerUserDate = Date(timeIntervalSince1970: 300)

        store.append(.init(sessionID: session.id, role: .assistant, title: "Assistant", text: "No activity", timestamp: assistantDate))
        XCTAssertNil(store.sessions.first(where: { $0.id == session.id })?.lastUserMessageAt)

        store.append(.init(sessionID: session.id, role: .user, title: "User", text: "Older", timestamp: olderUserDate))
        XCTAssertEqual(store.sessions.first(where: { $0.id == session.id })?.lastUserMessageAt, olderUserDate)

        store.append(.init(sessionID: session.id, role: .user, title: "User", text: "Newer", timestamp: newerUserDate))
        XCTAssertEqual(store.sessions.first(where: { $0.id == session.id })?.lastUserMessageAt, newerUserDate)

        store.append(.init(sessionID: session.id, role: .user, title: "User", text: "Older again", timestamp: olderUserDate))
        XCTAssertEqual(store.sessions.first(where: { $0.id == session.id })?.lastUserMessageAt, newerUserDate)
    }

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

    func testNoProjectCodingAgentSessionPersistsAsGeneralChat() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        let session = firstStore.createNoProjectCodingAgentSession(title: "General Chat")
        firstStore.flushForTesting()

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)
        await reloadedStore.waitForLoadForTesting()

        let reloaded = try XCTUnwrap(reloadedStore.sessions.first(where: { $0.id == session.id }))
        XCTAssertTrue(reloaded.isNoProject)
        XCTAssertNil(reloaded.projectPathForProjectFeatures)
        XCTAssertEqual(reloaded.projectNameForDisplay, "General Chat")
        XCTAssertEqual(reloaded.launchWorkingDirectory.path, PiAgentSessionRecord.generalChatScratchRootURL.appendingPathComponent(reloaded.id.uuidString, isDirectory: true).path)
        XCTAssertFalse(reloaded.subagentsEnabled)
    }

    func testDeletingGeneralChatSessionRemovesScratchFolders() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let store = PiAgentSessionStore(fileURL: fileURL)
        let session = store.createNoProjectCodingAgentSession(title: "General Chat")
        let currentURL = session.launchWorkingDirectory
        let legacyURL = session.legacyNoProjectLaunchWorkingDirectory
        try FileManager.default.createDirectory(at: currentURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: true)

        store.deleteSession(session.id)

        let removed = await PiTestSupport.waitUntilAsync {
            !FileManager.default.fileExists(atPath: currentURL.path)
                && !FileManager.default.fileExists(atPath: legacyURL.path)
        }
        XCTAssertTrue(removed)
    }

    func testTranscriptImagesMaterializeFromStructuredRawJSONAndPersistReference() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        let session = firstStore.createSession(kind: .project, title: "Images", project: try PiTestSupport.makeProject(), repository: nil)
        let rawJSON = #"{"content":[{"type":"image","mimeType":"image/png","name":"pixel.png","data":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="}]}"#

        firstStore.append(.init(sessionID: session.id, role: .assistant, title: "Assistant", text: "Here is an image", rawJSON: rawJSON))
        let entry = try XCTUnwrap(firstStore.transcriptsBySessionID[session.id]?.first)
        let reference = try XCTUnwrap(entry.imageReferences.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(reference.localPath)))
        firstStore.flushForTesting()

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)
        await reloadedStore.waitForLoadForTesting()
        let reloadedEntry = try XCTUnwrap(reloadedStore.transcriptForCacheUpdate(session.id).first)
        XCTAssertEqual(reloadedEntry.imageReferences.first?.name, "pixel.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(reference.localPath)))
    }

    func testMCPResultBlocksPersistInOrderWithoutBase64AndReload() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let store = PiAgentSessionStore(fileURL: fileURL)
        let session = store.createSession(kind: .project, title: "MCP", project: try PiTestSupport.makeProject(), repository: nil)
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
        let raw = """
        {"type":"tool_execution_end","toolName":"mcp","args":{"tool":"server/tool"},"result":{"content":[{"type":"text","text":"before"},{"type":"image","mimeType":"image/png","data":"\(png)"},{"type":"text","text":"after"}]}}
        """
        store.append(.init(sessionID: session.id, role: .tool, title: "Tool: mcp", text: "before\nafter", rawJSON: raw))
        let entry = try XCTUnwrap(store.transcriptsBySessionID[session.id]?.first)
        XCTAssertEqual(entry.mcpResultBlocks?.count, 3)
        guard case .text("before")? = entry.mcpResultBlocks?[0],
              case let .image(reference)? = entry.mcpResultBlocks?[1],
              case .text("after")? = entry.mcpResultBlocks?[2] else { return XCTFail("Expected text-image-text MCP blocks") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(reference.localPath)))
        XCTAssertFalse(try XCTUnwrap(entry.rawJSON).contains(png))
        XCTAssertFalse(entry.text.contains(png))
        store.flushForTesting()

        let reloaded = PiAgentSessionStore(fileURL: fileURL)
        await reloaded.waitForLoadForTesting()
        let restored = try XCTUnwrap(reloaded.transcriptForCacheUpdate(session.id).first)
        XCTAssertEqual(restored.mcpResultBlocks?.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(restored.allTranscriptImageReferences.first?.localPath)))
        XCTAssertFalse(restored.text.contains(png))
    }

    func testHistoricalMCPEntryWithoutBlocksDecodesTextOnlyAndCurrentBlocksReload() throws {
        let sessionID = UUID()
        let legacy = """
        {"id":"\(UUID().uuidString)","sessionID":"\(sessionID.uuidString)","role":"tool","title":"Tool: mcp","text":"legacy text","timestamp":0,"imageReferences":[]}
        """
        let legacyEntry = try JSONDecoder().decode(PiAgentTranscriptEntry.self, from: Data(legacy.utf8))
        XCTAssertNil(legacyEntry.mcpResultBlocks)
        XCTAssertEqual(legacyEntry.text, "legacy text")

        let current = PiAgentTranscriptEntry(sessionID: sessionID, role: .tool, title: "Tool: mcp", text: "current", mcpResultBlocks: [.text("current")])
        let reloaded = try JSONDecoder().decode(PiAgentTranscriptEntry.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(reloaded.mcpResultBlocks, [.text("current")])
    }

    func testLazySubagentPendingSnapshotKeepsSharedImageThroughTrimAndRewindUntilFinalRemoval() throws {
        let stateFile = PiTestSupport.temporaryStateFile()
        let store = PiAgentSessionStore(fileURL: stateFile)
        store.configureTranscriptMemory(lazyLoadingEnabled: true, cacheLimit: 1)
        let session = store.createSession(kind: .project, title: "Cleanup", project: try PiTestSupport.makeProject(), repository: nil)
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
        let mcpRaw = "{\"type\":\"tool_execution_end\",\"result\":{\"content\":[{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\"\(png)\"}]}}"
        store.append(.init(sessionID: session.id, role: .tool, title: "Tool: mcp", text: "", rawJSON: mcpRaw))
        let sharedReference = try XCTUnwrap(store.transcript(for: session.id).first?.allTranscriptImageReferences.first)
        let sharedPath = try XCTUnwrap(sharedReference.localPath)

        var protectedRun = PiSubagentRunRecord.failedPlaceholder(parentSessionID: session.id, agentName: "one", task: "one", error: "test")
        protectedRun.status = .completed
        var evictingRun = PiSubagentRunRecord.failedPlaceholder(parentSessionID: session.id, agentName: "two", task: "two", error: "test")
        evictingRun.status = .completed
        store.upsertSubagentRun(protectedRun)
        store.upsertSubagentRun(evictingRun)
        store.appendSubagentTranscript(.init(sessionID: session.id, role: .tool, title: "Tool: mcp", text: "shared", imageReferences: [sharedReference]), runID: protectedRun.id, parentSessionID: session.id)
        store.appendSubagentTranscript(.init(sessionID: session.id, role: .tool, title: "Tool: read", text: "evict"), runID: evictingRun.id, parentSessionID: session.id)
        XCTAssertFalse(store.hasCachedSubagentTranscript(for: protectedRun.id), "The shared reference must be retained only by its pending snapshot.")

        for index in 0..<500 {
            store.append(.init(sessionID: session.id, role: .assistant, title: "Assistant", text: "fill-\(index)"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedPath), "Trimming the original reference must respect the evicted run's pending snapshot.")

        let rewindEntry = PiAgentTranscriptEntry(sessionID: session.id, role: .tool, title: "Tool: mcp", text: "shared again", imageReferences: [sharedReference])
        store.append(rewindEntry)
        store.rewindSession(session.id, fromEntryID: rewindEntry.id, newPiSessionFile: "/tmp/rewound.jsonl", newPiSessionId: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedPath), "Rewinding another shared reference must retain the pending child reference.")

        store.clearSubagentTranscriptForTesting(protectedRun.id, parentSessionID: session.id)
        store.flushForTesting()
        XCTAssertTrue(PiTestSupport.waitUntil { !FileManager.default.fileExists(atPath: sharedPath) }, "The image must be deleted after its final pending reference is removed and flushed.")
    }

    func testVolatileSubagentStreamingUpsertsSkipCheckpointsUntilBoundaryPersistence() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let store = PiAgentSessionStore(fileURL: fileURL)
        let session = store.createSession(kind: .project, title: "Streaming", project: try PiTestSupport.makeProject(), repository: nil)
        let run = PiSubagentRunRecord.failedPlaceholder(parentSessionID: session.id, agentName: "Child", task: "Stream", error: "test")
        store.upsertSubagentRun(run)
        store.flushForTesting()

        let entryID = UUID()
        store.upsertSubagentTranscript(
            .init(id: entryID, sessionID: session.id, role: .assistant, title: "Assistant", text: "volatile"),
            runID: run.id,
            parentSessionID: session.id,
            persist: false
        )
        store.flushForTesting()

        let beforeBoundary = PiAgentSessionStore(fileURL: fileURL)
        await beforeBoundary.waitForLoadForTesting()
        XCTAssertFalse(beforeBoundary.hasPersistedSubagentTranscript(for: run.id))

        store.upsertSubagentTranscript(
            .init(id: entryID, sessionID: session.id, role: .assistant, title: "Assistant", text: "final persisted text"),
            runID: run.id,
            parentSessionID: session.id
        )
        store.flushForTesting()

        let reloaded = PiAgentSessionStore(fileURL: fileURL)
        await reloaded.waitForLoadForTesting()
        XCTAssertTrue(reloaded.hasPersistedSubagentTranscript(for: run.id))
        XCTAssertEqual(reloaded.subagentTranscript(for: run.id).map(\.text), ["final persisted text"])
    }

    func testMCPUpsertRemovesSupersededParentAndSubagentImages() async throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "MCP replacement", project: try PiTestSupport.makeProject(), repository: nil)
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
        func entry(id: UUID, type: String) -> PiAgentTranscriptEntry {
            let resultKey = type == "tool_execution_update" ? "partialResult" : "result"
            let raw = """
            {"type":"\(type)","\(resultKey)":{"content":[{"type":"image","mimeType":"image/png","data":"\(png)"}]}}
            """
            return .init(id: id, sessionID: session.id, role: .tool, title: "Tool: mcp", text: "", rawJSON: raw)
        }

        let parentEntryID = UUID()
        store.upsert(entry(id: parentEntryID, type: "tool_execution_update"))
        let parentPartialPath = try XCTUnwrap(store.transcript(for: session.id).first?.allTranscriptImageReferences.first?.localPath)
        store.upsert(entry(id: parentEntryID, type: "tool_execution_end"))
        let parentFinalPath = try XCTUnwrap(store.transcript(for: session.id).first?.allTranscriptImageReferences.first?.localPath)
        XCTAssertNotEqual(parentPartialPath, parentFinalPath)

        let run = PiSubagentRunRecord.failedPlaceholder(parentSessionID: session.id, agentName: "child", task: "child", error: "test")
        store.upsertSubagentRun(run)
        let childEntryID = UUID()
        store.upsertSubagentTranscript(entry(id: childEntryID, type: "tool_execution_update"), runID: run.id, parentSessionID: session.id)
        let childPartialPath = try XCTUnwrap(store.subagentTranscript(for: run.id).first?.allTranscriptImageReferences.first?.localPath)
        store.upsertSubagentTranscript(entry(id: childEntryID, type: "tool_execution_end"), runID: run.id, parentSessionID: session.id)
        let childFinalPath = try XCTUnwrap(store.subagentTranscript(for: run.id).first?.allTranscriptImageReferences.first?.localPath)
        XCTAssertNotEqual(childPartialPath, childFinalPath)

        let removed = await PiTestSupport.waitUntilAsync {
            !FileManager.default.fileExists(atPath: parentPartialPath)
                && !FileManager.default.fileExists(atPath: childPartialPath)
        }
        XCTAssertTrue(removed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: parentFinalPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: childFinalPath))
    }

    func testMCPResultWithMoreThan32BlocksScrubsAllImagesAndAppendsTruncationDiagnostic() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "MCP", project: try PiTestSupport.makeProject(), repository: nil)
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
        let content: [[String: String]] = (0..<40).map { index in
            index == 35
                ? ["type": "image", "mimeType": "image/png", "data": png]
                : ["type": "text", "text": "block-\(index)"]
        }
        let root: [String: Any] = ["type": "tool_execution_end", "result": ["content": content]]
        let raw = String(data: try JSONSerialization.data(withJSONObject: root), encoding: .utf8)!

        store.append(.init(sessionID: session.id, role: .tool, title: "Tool: mcp", text: png, rawJSON: raw))
        let entry = try XCTUnwrap(store.transcript(for: session.id).first)
        XCTAssertEqual(entry.mcpResultBlocks?.count, 33)
        XCTAssertEqual(entry.mcpResultBlocks?.prefix(32).compactMap { if case let .text(value) = $0 { return value }; return nil }, (0..<32).map { "block-\($0)" })
        XCTAssertEqual(entry.mcpResultBlocks?.last, .diagnostic("MCP result truncated after 32 blocks."))
        XCTAssertFalse(entry.text.contains(png))
        XCTAssertFalse(entry.rawJSON?.contains(png) == true)
    }

    func testMCPGeneratedImageURLsStayInsideSessionDirectoryAndAreRegularFiles() throws {
        let stateFile = PiTestSupport.temporaryStateFile()
        let store = PiAgentSessionStore(fileURL: stateFile)
        let session = store.createSession(kind: .project, title: "MCP", project: try PiTestSupport.makeProject(), repository: nil)
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
        let raw = #"{"type":"tool_execution_end","result":{"content":[{"type":"image","mimeType":"image/png","data":"\#(png)"}]}}"#
        store.append(.init(sessionID: session.id, role: .tool, title: "Tool: mcp", text: "", rawJSON: raw))
        let path = try XCTUnwrap(store.transcript(for: session.id).first?.allTranscriptImageReferences.first?.localPath)
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let expectedDirectory = stateFile.deletingLastPathComponent().appendingPathComponent("agent-session-transcripts/\(session.id.uuidString)/images", isDirectory: true).standardizedFileURL
        XCTAssertTrue(url.path.hasPrefix(expectedDirectory.path + "/"))
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        XCTAssertEqual(values.isRegularFile, true)
        XCTAssertNotEqual(values.isSymbolicLink, true)
    }

    func testMCPAggregateImageLimitRejectsExcessWithoutPersistingBase64() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "MCP", project: try PiTestSupport.makeProject(), repository: nil)
        let image = (Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0, count: 3 * 1024 * 1024)).base64EncodedString()
        let raw = "{\"type\":\"tool_execution_end\",\"result\":{\"content\":[{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\"\(image)\"},{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\"\(image)\"},{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\"\(image)\"}]}}"
        store.append(.init(sessionID: session.id, role: .tool, title: "Tool: mcp", text: image, rawJSON: raw))
        let entry = try XCTUnwrap(store.transcript(for: session.id).first)
        XCTAssertEqual(entry.allTranscriptImageReferences.count, 2)
        XCTAssertTrue(entry.mcpResultBlocks?.contains(.diagnostic("Invalid MCP image result was not saved.")) == true)
        XCTAssertFalse(entry.rawJSON?.contains(image) == true)
        XCTAssertFalse(entry.text.contains(image))
    }

    func testMCPRejectsInvalidBase64MimeMismatchAndOversizedImages() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "MCP", project: try PiTestSupport.makeProject(), repository: nil)
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let oversized = (pngHeader + Data(repeating: 0, count: 4 * 1024 * 1024)).base64EncodedString()
        let raw = """
        {"type":"tool_execution_end","result":{"content":[
          {"type":"image","mimeType":"image/png","data":"not-base64!"},
          {"type":"image","mimeType":"image/jpeg","data":"\(pngHeader.base64EncodedString())"},
          {"type":"image","mimeType":"image/png","data":"\(oversized)"}
        ]}}
        """
        store.append(.init(sessionID: session.id, role: .tool, title: "Tool: mcp", text: oversized, rawJSON: raw))
        let entry = try XCTUnwrap(store.transcriptsBySessionID[session.id]?.first)
        XCTAssertEqual(entry.mcpResultBlocks?.count, 3)
        XCTAssertTrue(entry.mcpResultBlocks?.allSatisfy { if case .diagnostic = $0 { return true }; return false } == true)
        XCTAssertTrue(entry.allTranscriptImageReferences.isEmpty)
        XCTAssertFalse(entry.text.contains(oversized))
        XCTAssertFalse(entry.rawJSON?.contains(oversized) == true)
    }

    func testImageOnlyMCPResultUsesSafeTextWithoutBase64() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "MCP", project: try PiTestSupport.makeProject(), repository: nil)
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
        let raw = "{\"type\":\"tool_execution_end\",\"result\":{\"content\":[{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\"\(png)\"}]}}"
        store.append(.init(sessionID: session.id, role: .tool, title: "Tool: mcp", text: png, rawJSON: raw))
        let entry = try XCTUnwrap(store.transcriptsBySessionID[session.id]?.first)
        XCTAssertEqual(entry.text, "MCP returned an image.")
        XCTAssertFalse(entry.rawJSON?.contains(png) == true)
    }

    func testInvalidMCPImageIsDiagnosticAndDoesNotWriteFile() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "MCP", project: try PiTestSupport.makeProject(), repository: nil)
        let raw = #"{"type":"tool_execution_end","result":{"content":[{"type":"image","mimeType":"image/png","data":"bm90LWFuLWltYWdl"}]}}"#
        store.append(.init(sessionID: session.id, role: .tool, title: "Tool: mcp", text: "", rawJSON: raw))
        let entry = try XCTUnwrap(store.transcriptsBySessionID[session.id]?.first)
        guard case .diagnostic? = entry.mcpResultBlocks?.first else { return XCTFail("Expected safe diagnostic") }
        XCTAssertTrue(entry.allTranscriptImageReferences.isEmpty)
        XCTAssertFalse(try XCTUnwrap(entry.rawJSON).contains("bm90LWFuLWltYWdl"))
    }

    func testUserTranscriptImagesMaterializeFromMarkdownAndPlainDataURLs() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "User Images", project: try PiTestSupport.makeProject(), repository: nil)
        let dataURL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="

        store.append(.init(sessionID: session.id, role: .user, title: "You", text: "![pixel](\(dataURL))\n\(dataURL)"))

        let entry = try XCTUnwrap(store.transcriptsBySessionID[session.id]?.first)
        XCTAssertFalse(entry.imageReferences.isEmpty)
        XCTAssertTrue(entry.imageReferences.allSatisfy { reference in
            guard let localPath = reference.localPath else { return false }
            return FileManager.default.fileExists(atPath: localPath)
        })
    }

    func testToolTextMarkdownImagesDoNotMaterialize() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Tool Text Images", project: try PiTestSupport.makeProject(), repository: nil)

        store.append(.init(
            sessionID: session.id,
            role: .tool,
            title: "Tool: read",
            text: #"renderMarkdownPreview("![Alt](https://example.com/image.png)")"#
        ))

        let entry = try XCTUnwrap(store.transcriptsBySessionID[session.id]?.first)
        XCTAssertTrue(entry.imageReferences.isEmpty)
    }

    func testToolErrorTextMarkdownImagesDoNotMaterialize() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Tool Error Text Images", project: try PiTestSupport.makeProject(), repository: nil)

        store.append(.init(
            sessionID: session.id,
            role: .error,
            title: "Tool: read",
            text: #"failed while reading: ![Alt](https://example.com/image.png)"#
        ))

        let entry = try XCTUnwrap(store.transcriptsBySessionID[session.id]?.first)
        XCTAssertTrue(entry.imageReferences.isEmpty)
    }

    func testToolStructuredRawJSONImagesStillMaterialize() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Tool Raw Images", project: try PiTestSupport.makeProject(), repository: nil)
        let rawJSON = #"{"content":[{"type":"image","mimeType":"image/png","name":"pixel.png","data":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="}]}"#

        store.append(.init(sessionID: session.id, role: .tool, title: "Tool: screenshot", text: "Captured screenshot", rawJSON: rawJSON))
        store.append(.init(sessionID: session.id, role: .error, title: "Tool: screenshot", text: "Captured screenshot fallback", rawJSON: rawJSON))

        let entries = try XCTUnwrap(store.transcriptsBySessionID[session.id])
        XCTAssertEqual(entries.count, 2)
        for entry in entries {
            let reference = try XCTUnwrap(entry.imageReferences.first)
            XCTAssertEqual(reference.name, "pixel.png")
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(reference.localPath)))
        }
    }

    func testUserTranscriptRemoteImageUsesPlaceholderAndSafeDownloadPath() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "User Remote", project: try PiTestSupport.makeProject(), repository: nil)

        store.append(.init(sessionID: session.id, role: .user, title: "You", text: "Screenshot: https://example.com/pixel.png"))

        let reference = try XCTUnwrap(store.transcriptsBySessionID[session.id]?.first?.imageReferences.first)
        XCTAssertNil(reference.localPath)
        XCTAssertEqual(reference.remoteURL, "https://example.com/pixel.png")
        XCTAssertTrue(reference.isRemotePlaceholder)
    }

    func testPlainImageURLDetectionSkipsLinksAndCode() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Protected URLs", project: try PiTestSupport.makeProject(), repository: nil)

        store.append(.init(
            sessionID: session.id,
            role: .user,
            title: "You",
            text: "[watch](https://example.com/pixel.png) `https://example.com/inline.png`\n```\nhttps://example.com/fenced.png\n```"
        ))

        let entry = try XCTUnwrap(store.transcriptsBySessionID[session.id]?.first)
        XCTAssertTrue(entry.imageReferences.isEmpty)
    }

    func testDeletingSessionRemovesTranscriptImageStorage() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let store = PiAgentSessionStore(fileURL: fileURL)
        let session = store.createSession(kind: .project, title: "Images", project: try PiTestSupport.makeProject(), repository: nil)
        let rawJSON = #"{"type":"image","mimeType":"image/png","name":"pixel.png","data":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="}"#
        store.append(.init(sessionID: session.id, role: .assistant, title: "Assistant", text: "Image", rawJSON: rawJSON))
        let reference = try XCTUnwrap(store.transcriptsBySessionID[session.id]?.first?.imageReferences.first)
        let imageDirectory = URL(fileURLWithPath: try XCTUnwrap(reference.localPath)).deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageDirectory.path))

        store.deleteSession(session.id)

        let removed = await PiTestSupport.waitUntilAsync {
            !FileManager.default.fileExists(atPath: imageDirectory.path)
        }
        XCTAssertTrue(removed)
    }

    func testSessionTracksAllOwnedPiFilesAcrossInPlaceRebindsAndReload() async throws {
        let stateFile = PiTestSupport.temporaryStateFile()
        let store = PiAgentSessionStore(fileURL: stateFile)
        let session = store.createSession(kind: .project, title: "Branches", project: try PiTestSupport.makeProject(), repository: nil)
        store.updateSession(session.id) { $0.recordPiSessionFile("/tmp/first.jsonl") }
        store.updateSession(session.id) { $0.recordPiSessionFile("/tmp/second.jsonl") }
        XCTAssertEqual(Set(store.sessions.first(where: { $0.id == session.id })?.ownedPiSessionFiles ?? []), ["/tmp/first.jsonl", "/tmp/second.jsonl"])
        store.flushForTesting()

        let reloaded = PiAgentSessionStore(fileURL: stateFile)
        await reloaded.waitForLoadForTesting()
        XCTAssertEqual(Set(reloaded.sessions.first(where: { $0.id == session.id })?.ownedPiSessionFiles ?? []), ["/tmp/first.jsonl", "/tmp/second.jsonl"])
    }

    func testSessionOwnedArtifactCleanupRemovesOnlyValidatedPiAndSubagentFiles() throws {
        let root = PiTestSupport.temporaryStateFile().deletingLastPathComponent()
        let piRoot = root.appendingPathComponent("pi-sessions", isDirectory: true)
        let piProject = piRoot.appendingPathComponent("project", isDirectory: true)
        let runRoot = root.appendingPathComponent("Subagent Runs", isDirectory: true)
        let runID = UUID()
        let runDirectory = runRoot.appendingPathComponent(runID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: piProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let piFile = piProject.appendingPathComponent("parent-session.jsonl")
        let childPiFile = piProject.appendingPathComponent("child-session.jsonl")
        let outsideFile = root.appendingPathComponent("outside.jsonl")
        try Data("session".utf8).write(to: piFile)
        try Data("child".utf8).write(to: childPiFile)
        try Data("outside".utf8).write(to: outsideFile)
        try Data("artifact".utf8).write(to: runDirectory.appendingPathComponent("output.md"))
        var run = PiSubagentRunRecord.failedPlaceholder(parentSessionID: UUID(), agentName: "child", task: "child", error: "test")
        run.childPiSessionFile = childPiFile.path
        XCTAssertEqual(PiAgentSessionOwnedArtifactCleanup.childPiSessionFiles(in: [run]), [childPiFile.path])

        PiAgentSessionOwnedArtifactCleanup.delete(
            piSessionFiles: [piFile.path, childPiFile.path, outsideFile.path],
            subagentRunIDs: [runID],
            piSessionsRoot: piRoot,
            subagentRunsRoot: runRoot
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: piFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: childPiFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    func testDeletedSessionRejectsLateTranscriptAndSubagentImageWrites() async throws {
        let stateFile = PiTestSupport.temporaryStateFile()
        let store = PiAgentSessionStore(fileURL: stateFile)
        let session = store.createSession(kind: .project, title: "Deleted", project: try PiTestSupport.makeProject(), repository: nil)
        let run = PiSubagentRunRecord.failedPlaceholder(parentSessionID: session.id, agentName: "child", task: "late", error: "test")
        store.upsertSubagentRun(run)
        let directory = stateFile.deletingLastPathComponent()
            .appendingPathComponent("agent-session-transcripts/\(session.id.uuidString)/images", isDirectory: true)
        store.deleteSession(session.id)

        let raw = #"{"type":"tool_execution_end","result":{"content":[{"type":"image","mimeType":"image/png","data":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="}]}}"#
        let lateEntry = PiAgentTranscriptEntry(sessionID: session.id, role: .tool, title: "Tool: mcp", text: "", rawJSON: raw)
        store.append(lateEntry)
        store.upsert(lateEntry)
        store.upsertSubagentRun(run)
        store.appendSubagentTranscript(lateEntry, runID: run.id, parentSessionID: session.id)
        store.upsertSubagentTranscript(lateEntry, runID: run.id, parentSessionID: session.id)
        store.flushForTesting()

        XCTAssertNil(store.transcriptsBySessionID[session.id])
        XCTAssertNil(store.subagentRunsBySessionID[session.id])
        XCTAssertNil(store.subagentTranscriptsByRunID[run.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRemoteImageCompletionAfterSessionDeletionDoesNotRecreateStorage() async throws {
        defer { PiAgentSessionStore.remoteImageDownloaderForTesting = nil }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")!
        PiAgentSessionStore.remoteImageDownloaderForTesting = { _ in
            try await Task.sleep(for: .milliseconds(150))
            return (png, "image/png")
        }
        let stateFile = PiTestSupport.temporaryStateFile()
        let store = PiAgentSessionStore(fileURL: stateFile)
        let session = store.createSession(kind: .project, title: "Deleted remote", project: try PiTestSupport.makeProject(), repository: nil)
        let directory = stateFile.deletingLastPathComponent()
            .appendingPathComponent("agent-session-transcripts/\(session.id.uuidString)/images", isDirectory: true)

        store.append(.init(sessionID: session.id, role: .assistant, title: "Assistant", text: "![remote](https://example.com/pixel.png)"))
        store.deleteSession(session.id)
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNil(store.transcriptsBySessionID[session.id])
    }

    func testTranscriptImagesAreNotMaterializedForStatusRows() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Images", project: try PiTestSupport.makeProject(), repository: nil)
        let rawJSON = #"{"type":"image","mimeType":"image/png","name":"pixel.png","data":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="}"#

        store.append(.init(sessionID: session.id, role: .status, title: "Status", text: "![pixel](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=)", rawJSON: rawJSON))

        let entry = try XCTUnwrap(store.transcriptsBySessionID[session.id]?.first)
        XCTAssertTrue(entry.imageReferences.isEmpty)
    }

    func testRemoteTranscriptImageDefaultsToPersistedPlaceholder() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Remote", project: try PiTestSupport.makeProject(), repository: nil)

        store.append(.init(sessionID: session.id, role: .assistant, title: "Assistant", text: "![remote](https://example.com/pixel.png)"))

        let reference = try XCTUnwrap(store.transcriptsBySessionID[session.id]?.first?.imageReferences.first)
        XCTAssertNil(reference.localPath)
        XCTAssertEqual(reference.remoteURL, "https://example.com/pixel.png")
        XCTAssertTrue(reference.isRemotePlaceholder)
    }

    func testRemoteTranscriptImageAutoDownloadMaterializesFile() async throws {
        defer { PiAgentSessionStore.remoteImageDownloaderForTesting = nil }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")!
        PiAgentSessionStore.remoteImageDownloaderForTesting = { url in
            XCTAssertEqual(url.absoluteString, "https://example.com/pixel.png")
            return (png, "image/png")
        }
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Remote", project: try PiTestSupport.makeProject(), repository: nil)

        store.append(.init(sessionID: session.id, role: .assistant, title: "Assistant", text: "![remote](https://example.com/pixel.png)"))

        let materialized = await PiTestSupport.waitUntilAsync {
            guard let reference = store.transcriptsBySessionID[session.id]?.first?.imageReferences.first,
                  let localPath = reference.localPath else { return false }
            return FileManager.default.fileExists(atPath: localPath)
        }
        XCTAssertTrue(materialized)
    }

    func testRemoteTranscriptImagePlaceholderPersistsAcrossReload() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        let session = firstStore.createSession(kind: .project, title: "Remote", project: try PiTestSupport.makeProject(), repository: nil)
        firstStore.append(.init(sessionID: session.id, role: .assistant, title: "Assistant", text: "![remote](https://example.com/pixel.png)"))
        firstStore.flushForTesting()

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)
        await reloadedStore.waitForLoadForTesting()
        let reference = try XCTUnwrap(reloadedStore.transcriptForCacheUpdate(session.id).first?.imageReferences.first)
        XCTAssertNil(reference.localPath)
        XCTAssertEqual(reference.remoteURL, "https://example.com/pixel.png")
    }

    func testClearingTranscriptRemovesTranscriptImageStorage() async throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Images", project: try PiTestSupport.makeProject(), repository: nil)
        let rawJSON = #"{"type":"image","mimeType":"image/png","name":"pixel.png","data":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="}"#
        store.append(.init(sessionID: session.id, role: .assistant, title: "Assistant", text: "Image", rawJSON: rawJSON))
        let reference = try XCTUnwrap(store.transcriptsBySessionID[session.id]?.first?.imageReferences.first)
        let imageDirectory = URL(fileURLWithPath: try XCTUnwrap(reference.localPath)).deletingLastPathComponent()

        store.clearTranscript(for: session.id)

        let removed = await PiTestSupport.waitUntilAsync {
            !FileManager.default.fileExists(atPath: imageDirectory.path)
        }
        XCTAssertTrue(removed)
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

    func testLazyLoadDiscoversTranscriptOmittedFromValidManifest() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        let session = firstStore.createSession(kind: .project, title: "Manifest omission", project: try PiTestSupport.makeProject(), repository: nil)
        firstStore.append(.init(sessionID: session.id, role: .user, title: "User", text: "preserved transcript"))
        firstStore.flushForTesting()
        try writeManifest(parentSessionIDs: [], subagentRunIDs: [], for: fileURL)

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)
        await reloadedStore.waitForLoadForTesting()

        XCTAssertTrue(reloadedStore.hasPersistedTranscript(for: session.id))
        XCTAssertEqual(reloadedStore.transcript(for: session.id).map(\.text), ["preserved transcript"])
        let manifestWasRewritten = await PiTestSupport.waitUntilAsync {
            self.manifestParentSessionIDs(for: fileURL).contains(session.id)
        }
        XCTAssertTrue(manifestWasRewritten)
    }

    func testLazyLoadDiscoversSubagentTranscriptOmittedFromValidManifest() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        let session = firstStore.createSession(kind: .project, title: "Subagent manifest omission", project: try PiTestSupport.makeProject(), repository: nil)
        let run = PiSubagentRunRecord.failedPlaceholder(parentSessionID: session.id, agentName: "Test", task: "Recover transcript", error: "Stopped")
        firstStore.upsertSubagentRun(run)
        firstStore.appendSubagentTranscript(
            .init(sessionID: session.id, role: .assistant, title: "Assistant", text: "preserved subagent transcript"),
            runID: run.id,
            parentSessionID: session.id
        )
        firstStore.flushForTesting()
        try writeManifest(parentSessionIDs: [], subagentRunIDs: [], for: fileURL)

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)
        await reloadedStore.waitForLoadForTesting()

        XCTAssertTrue(reloadedStore.hasPersistedSubagentTranscript(for: run.id))
        XCTAssertEqual(reloadedStore.subagentTranscript(for: run.id).map(\.text), ["preserved subagent transcript"])
    }

    func testLazyLoadRecoversCurrentIndexWhenManifestIsMissingOrCorrupt() async throws {
        for corruptManifest in [false, true] {
            let fileURL = PiTestSupport.temporaryStateFile()
            let firstStore = PiAgentSessionStore(fileURL: fileURL)
            let session = firstStore.createSession(kind: .project, title: "Manifest recovery", project: try PiTestSupport.makeProject(), repository: nil)
            firstStore.append(.init(sessionID: session.id, role: .user, title: "User", text: "preserved transcript"))
            firstStore.flushForTesting()
            let manifestURL = transcriptManifestURL(for: fileURL)
            if corruptManifest {
                try Data("not JSON".utf8).write(to: manifestURL, options: .atomic)
            } else {
                try FileManager.default.removeItem(at: manifestURL)
            }

            let reloadedStore = PiAgentSessionStore(fileURL: fileURL)
            await reloadedStore.waitForLoadForTesting()

            XCTAssertEqual(reloadedStore.sessions.map(\.id), [session.id])
            XCTAssertTrue(reloadedStore.hasPersistedTranscript(for: session.id))
            XCTAssertEqual(reloadedStore.transcript(for: session.id).map(\.text), ["preserved transcript"])
        }
    }

    func testLazyLoadIgnoresOrphanTranscriptFile() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        let session = firstStore.createSession(kind: .project, title: "Known", project: try PiTestSupport.makeProject(), repository: nil)
        firstStore.append(.init(sessionID: session.id, role: .user, title: "User", text: "known transcript"))
        firstStore.flushForTesting()

        let orphanID = UUID()
        let directory = transcriptManifestURL(for: fileURL).deletingLastPathComponent()
        let knownURL = directory.appendingPathComponent("parent-\(session.id.uuidString).json")
        let orphanURL = directory.appendingPathComponent("parent-\(orphanID.uuidString).json")
        try FileManager.default.copyItem(at: knownURL, to: orphanURL)

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)
        await reloadedStore.waitForLoadForTesting()

        XCTAssertTrue(reloadedStore.hasPersistedTranscript(for: session.id))
        XCTAssertFalse(reloadedStore.hasPersistedTranscript(for: orphanID))
    }

    func testLegacyEmbeddedStateMigratesWithoutDiscardingTranscript() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        firstStore.configureTranscriptMemory(lazyLoadingEnabled: false, cacheLimit: 1)
        let session = firstStore.createSession(kind: .project, title: "Legacy", project: try PiTestSupport.makeProject(), repository: nil)
        firstStore.append(.init(sessionID: session.id, role: .user, title: "User", text: "legacy transcript"))
        firstStore.flushForTesting()

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)
        await reloadedStore.waitForLoadForTesting()

        XCTAssertEqual(reloadedStore.sessions.map(\.id), [session.id])
        XCTAssertEqual(reloadedStore.transcript(for: session.id).map(\.text), ["legacy transcript"])
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

    private func transcriptManifestURL(for fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("agent-session-transcripts", isDirectory: true)
            .appendingPathComponent("manifest.json")
    }

    private func manifestParentSessionIDs(for fileURL: URL) -> Set<UUID> {
        guard let data = try? Data(contentsOf: transcriptManifestURL(for: fileURL)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawIDs = object["parentSessionIDs"] as? [String] else { return [] }
        return Set(rawIDs.compactMap(UUID.init(uuidString:)))
    }

    private func writeManifest(parentSessionIDs: [UUID], subagentRunIDs: [UUID], for fileURL: URL) throws {
        let object: [String: Any] = [
            "parentSessionIDs": parentSessionIDs.map(\.uuidString),
            "subagentRunIDs": subagentRunIDs.map(\.uuidString)
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: transcriptManifestURL(for: fileURL), options: .atomic)
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
