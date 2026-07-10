import XCTest
@testable import agent_deck

@MainActor
final class LoopSkeletonTests: XCTestCase {
    func testSlashUniverseIncludesLoopsCategoryAndCreateNewLoop() {
        let item = SlashItem(
            id: "loop:create-new",
            kind: .loop,
            displayName: "Create New Loop…",
            description: nil,
            scopeLabel: "Unsaved",
            isActive: true,
            payload: .loopCreateNew
        )
        let universe = SlashUniverse(skills: [], prompts: [], commands: [], loops: [item])

        let categories = SlashSuggestionRowBuilder.rows(universe: universe, state: .init(), query: "")
        XCTAssertTrue(categories.contains { row in
            if case .category(.loop) = row.kind { return true }
            return false
        })

        let loopRows = SlashSuggestionRowBuilder.rows(
            universe: universe,
            state: SlashSuggestionState(screen: .category(.loop)),
            query: ""
        )
        XCTAssertEqual(loopRows.compactMap { row -> String? in
            if case .item(let item) = row.kind { return item.displayName }
            return nil
        }, ["Create New Loop…"])
        XCTAssertEqual(item.materialize(userText: "do not send"), "do not send")
    }

    func testParallelLoopDefaultsRequireExplicitAgents() {
        XCTAssertTrue(LoopParallelConfig().branchNames.isEmpty)
        let legacy = LoopParallelConfig(branchNames: ["Branch A", "Branch A", " Branch B "])
        XCTAssertEqual(legacy.branchNames, ["Branch A", "Branch B"])
    }

    func testAppViewModelRejectsParallelLoopWithMissingSelectedAgent() async throws {
        let viewModel = AppViewModel()
        let session = viewModel.piAgentSessionStore.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(), repository: nil)
        let draft = LoopDraft(goal: "Compare", structure: .parallelAgents, parallel: LoopParallelConfig(branchNames: ["Definitely Missing Agent"]))

        let launched = await viewModel.launchLoop(session: session, draft: draft, stopExistingActive: false)

        XCTAssertNil(launched)
        XCTAssertTrue(viewModel.piAgentSessionStore.transcript(for: session.id).contains { $0.title == "Loop Agent Unavailable" })
    }

    func testApprovalCheckpointRecordsApprovalWithoutClaimingCompletion() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(), repository: nil)
        let checkpoint = try XCTUnwrap(store.launchSmokeLoop(sessionID: session.id, projectPath: session.projectPath, draft: LoopDraft(goal: "Approve", structure: .humanApproval)))
        let resolved = try XCTUnwrap(store.resolveHumanApprovalLoopRun(checkpoint.id, sessionID: session.id, approved: true))

        XCTAssertEqual(resolved.status, .stopped)
        XCTAssertEqual(resolved.stopReason, .humanApproved)
        XCTAssertFalse(LoopRunRecapCodec.finalText(for: resolved).contains("Outcome: Success"))
        XCTAssertTrue(NativeLoopRunPayload.make(run: resolved, onStop: nil, onRetry: nil, onSave: nil, onRevealArtifacts: nil, onRevealWorktree: nil).canRetry)
    }

    func testLoopCardPayloadShowsStopReasonAndCheckerRejectionOutcome() throws {
        let draft = LoopDraft(
            goal: "Fix until checker approves",
            structure: .makerChecker,
            maxIterations: 2,
            makerChecker: LoopMakerCheckerConfig(makerName: "Maker", checkerName: "Checker", checkerRubric: "approve")
        )
        var run = LoopRun(sessionID: UUID(), projectPath: nil, draft: draft)
        run.status = .notAchieved
        run.currentIteration = 2
        run.endedAt = Date()
        run.stopReason = .maxIterationsReached
        run.iterations = [
            LoopIteration(index: 1, checkerResult: .reject),
            LoopIteration(index: 2, checkerResult: .reject)
        ]

        let payload = NativeLoopRunPayload.make(
            run: run,
            onStop: nil,
            onRetry: nil,
            onSave: nil,
            onRevealArtifacts: nil,
            onRevealWorktree: nil
        )

        XCTAssertTrue(payload.statusText.contains("Status: Goal not achieved"))
        XCTAssertFalse(payload.statusText.contains("Status: Failed"))
        XCTAssertTrue(payload.canRetry)
        XCTAssertTrue(payload.statusText.contains("Stop reason: Max iterations reached"))
        XCTAssertTrue(payload.statusText.contains("Last checker: Reject"))
    }

    func testHistoricalCompletedCapPresentsGoalNotAchieved() {
        let draft = LoopDraft(goal: "Legacy", structure: .singleAgent, maxIterations: 1)
        var run = LoopRun(sessionID: UUID(), projectPath: nil, draft: draft)
        run.status = .completed
        run.stopReason = .maxIterationsReached
        run.iterations = [LoopIteration(index: 1, checkerResult: .reject)]

        XCTAssertTrue(run.presentsGoalNotMetOutcome)
        XCTAssertEqual(run.displayStatusName, "Goal not achieved")
    }

    func testLoopCardDetailsExposeLaunchContextButMainTranscriptStaysConcise() throws {
        let draft = LoopDraft(
            goal: "Use launch notes",
            launchContext: "Sensitive repro notes\nSecond line",
            launchContextScope: .everyIteration,
            validationCommand: "/usr/bin/true"
        )
        var run = LoopRun(sessionID: UUID(), projectPath: nil, draft: draft)
        run.status = .completed
        run.currentIteration = 1
        run.endedAt = Date()
        run.stopReason = .success

        let payload = NativeLoopRunPayload.make(
            run: run,
            onStop: nil,
            onRetry: nil,
            onSave: nil,
            onRevealArtifacts: nil,
            onRevealWorktree: nil
        )
        let transcriptText = LoopRunTranscriptCodec.transcriptText(for: run)

        XCTAssertTrue(payload.detailText.contains("Launch Context"))
        XCTAssertTrue(payload.detailText.contains("Scope: Every iteration"))
        XCTAssertTrue(payload.detailText.contains("Sensitive repro notes\nSecond line"))
        XCTAssertTrue(transcriptText.contains("Launch context: present (every iteration)"))
        XCTAssertFalse(transcriptText.contains("Sensitive repro notes"))
    }

    func testSmokeLoopLaunchCompletesAndWritesFileBackedTranscriptCard() throws {
        let stateFile = PiTestSupport.temporaryStateFile()
        let projectURL = try PiTestSupport.temporaryProjectURL()
        let store = PiAgentSessionStore(fileURL: stateFile)
        let session = store.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(url: projectURL), repository: nil)

        let run = try XCTUnwrap(store.launchSmokeLoop(
            sessionID: session.id,
            projectPath: session.projectPath,
            draft: LoopDraft(goal: "Produce a markdown smoke artifact", validationCommand: "/usr/bin/true")
        ))
        let artifact = try XCTUnwrap(run.iterations.first?.artifacts.first)
        let artifactPath = try XCTUnwrap(artifact.filePath)
        let artifactDirectoryPath = try XCTUnwrap(run.artifactDirectoryPath)

        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.stopReason, .success)
        XCTAssertEqual(run.currentIteration, 1)
        XCTAssertEqual(artifact.filename, "loop-smoke.md")
        XCTAssertEqual(run.iterations.first?.validationResult?.exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactPath))
        XCTAssertEqual(try String(contentsOfFile: artifactPath, encoding: .utf8), artifact.markdown)
        XCTAssertTrue(path(artifactPath, isUnder: stateFile.deletingLastPathComponent().path))
        XCTAssertTrue(path(artifactDirectoryPath, isUnder: stateFile.deletingLastPathComponent().path))
        XCTAssertFalse(path(artifactPath, isUnder: projectURL.path))
        XCTAssertNil(store.activeLoopRun(for: session.id))

        let loopEntries = store.transcript(for: session.id).filter { $0.title == LoopRunTranscriptCodec.title }
        XCTAssertEqual(loopEntries.count, 1)
        XCTAssertTrue(loopEntries[0].text.contains("Stop reason: Success"))
        XCTAssertTrue(loopEntries[0].text.contains("Artifact directory: \(artifactDirectoryPath)"))
        XCTAssertTrue(loopEntries[0].text.contains("Artifact path: \(artifactPath)"))
        XCTAssertTrue(loopEntries[0].text.contains("# Loop Smoke Output"))
        XCTAssertEqual(LoopRunTranscriptCodec.decode(from: loopEntries[0])?.id, run.id)
        XCTAssertTrue(loopEntries[0].isLoopTranscriptCard)
    }

    func testArtifactWriteTargetDoesNotModifyProjectTree() throws {
        let stateFile = PiTestSupport.temporaryStateFile()
        let projectURL = try PiTestSupport.temporaryProjectURL()
        let sentinelURL = projectURL.appendingPathComponent("sentinel.txt")
        try "original".write(to: sentinelURL, atomically: true, encoding: .utf8)
        let before = try projectEntries(at: projectURL)
        let store = PiAgentSessionStore(fileURL: stateFile)
        let session = store.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(url: projectURL), repository: nil)

        let run = try XCTUnwrap(store.launchSmokeLoop(
            sessionID: session.id,
            projectPath: session.projectPath,
            draft: LoopDraft(goal: "Artifact only", writeTarget: .artifactMarkdown, validationCommand: "/usr/bin/true")
        ))

        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(try projectEntries(at: projectURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("loop-smoke-write-target.txt").path))
    }

    func testCurrentCheckoutWritesKnownFileOnlyWhenExplicitlySelected() throws {
        let stateFile = PiTestSupport.temporaryStateFile()
        let projectURL = try PiTestSupport.temporaryProjectURL()
        let store = PiAgentSessionStore(fileURL: stateFile)
        let session = store.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(url: projectURL), repository: nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("loop-smoke-write-target.txt").path))
        let run = try XCTUnwrap(store.launchSmokeLoop(
            sessionID: session.id,
            projectPath: session.projectPath,
            draft: LoopDraft(goal: "Direct write", writeTarget: .currentCheckout, validationCommand: "/bin/pwd")
        ))

        let smokeURL = projectURL.appendingPathComponent("loop-smoke-write-target.txt")
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.iterations.first?.changedFiles, ["loop-smoke-write-target.txt"])
        XCTAssertEqual(run.iterations.first?.validationResult?.workingDirectory, projectURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: smokeURL.path))
    }

    func testWorktreeTargetKeepsCurrentCheckoutUntouchedAndValidatesInWorktree() throws {
        let stateFile = PiTestSupport.temporaryStateFile()
        let projectURL = try makeTemporaryGitRepository()
        let before = try projectEntries(at: projectURL)
        let store = PiAgentSessionStore(fileURL: stateFile)
        let session = store.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(url: projectURL), repository: nil)

        let run = try XCTUnwrap(store.launchSmokeLoop(
            sessionID: session.id,
            projectPath: session.projectPath,
            draft: LoopDraft(goal: "Worktree write", writeTarget: .newWorktree, validationCommand: "test -f loop-smoke-write-target.txt")
        ))

        let worktreePath = try XCTUnwrap(run.iterations.first?.validationResult?.workingDirectory)
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.stopReason, .success)
        XCTAssertTrue(path(worktreePath, isUnder: try XCTUnwrap(run.artifactDirectoryPath)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: worktreePath).appendingPathComponent("loop-smoke-write-target.txt").path))
        XCTAssertEqual(try projectEntries(at: projectURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("loop-smoke-write-target.txt").path))
        XCTAssertEqual(run.iterations.first?.changedFiles, ["loop-smoke-write-target.txt"])
    }

    func testHydratingTranscriptWithoutLoopEntriesClearsCachedLoopRuns() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(), repository: nil)
        _ = try XCTUnwrap(store.launchSmokeLoop(
            sessionID: session.id,
            projectPath: session.projectPath,
            draft: LoopDraft(goal: "Temporary loop", validationCommand: "/usr/bin/true")
        ))
        XCTAssertFalse(store.loopRuns(for: session.id).isEmpty)

        store.updateEntry(store.transcript(for: session.id)[0].id, in: session.id) { entry in
            entry.title = "Other Status"
            entry.rawJSON = nil
        }
        store.hydrateLoopRunsFromTranscript(sessionID: session.id)

        XCTAssertTrue(store.loopRuns(for: session.id).isEmpty)
    }

    func testLoopRunsHydrateFromPersistedTranscript() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        firstStore.configureTranscriptMemory(lazyLoadingEnabled: false, cacheLimit: 10)
        let session = firstStore.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(), repository: nil)
        let run = try XCTUnwrap(firstStore.launchSmokeLoop(
            sessionID: session.id,
            projectPath: session.projectPath,
            draft: LoopDraft(goal: "Persist this loop card", validationCommand: "/usr/bin/true")
        ))
        firstStore.flushForTesting()

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)
        await reloadedStore.waitForLoadForTesting()
        reloadedStore.configureTranscriptMemory(lazyLoadingEnabled: false, cacheLimit: 10)

        let hydratedRun = try XCTUnwrap(reloadedStore.loopRuns(for: session.id).first)
        let hydratedArtifact = try XCTUnwrap(hydratedRun.iterations.first?.artifacts.first)
        XCTAssertEqual(hydratedRun.id, run.id)
        XCTAssertEqual(hydratedRun.stopReason, .success)
        XCTAssertEqual(hydratedRun.artifactDirectoryPath, run.artifactDirectoryPath)
        XCTAssertEqual(hydratedArtifact.filePath, run.iterations.first?.artifacts.first?.filePath)
        XCTAssertEqual(hydratedRun.iterations.first?.validationResult?.exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(hydratedArtifact.filePath)))
    }

    func testNormalHydrationPreservesActiveLoopRun() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(), repository: nil)
        let activeRun = LoopRun(
            sessionID: session.id,
            projectPath: session.projectPath,
            draft: LoopDraft(goal: "Active loop", validationCommand: "/usr/bin/true")
        )
        store.append(LoopRunTranscriptCodec.transcriptEntry(for: activeRun))

        store.hydrateLoopRunsFromTranscript(sessionID: session.id)

        let hydrated = try XCTUnwrap(store.loopRuns(for: session.id).first)
        XCTAssertEqual(hydrated.id, activeRun.id)
        XCTAssertEqual(hydrated.status, .running)
        XCTAssertNil(hydrated.stopReason)
    }

    func testReloadingPersistedActiveLoopRunMarksInterrupted() async throws {
        let fileURL = PiTestSupport.temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        firstStore.configureTranscriptMemory(lazyLoadingEnabled: false, cacheLimit: 10)
        let session = firstStore.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(), repository: nil)
        let activeRun = LoopRun(
            sessionID: session.id,
            projectPath: session.projectPath,
            draft: LoopDraft(goal: "Interrupted loop", validationCommand: "/usr/bin/true")
        )
        firstStore.append(LoopRunTranscriptCodec.transcriptEntry(for: activeRun))
        firstStore.flushForTesting()

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)
        await reloadedStore.waitForLoadForTesting()
        reloadedStore.configureTranscriptMemory(lazyLoadingEnabled: false, cacheLimit: 10)

        let hydrated = try XCTUnwrap(reloadedStore.loopRuns(for: session.id).first)
        XCTAssertEqual(hydrated.id, activeRun.id)
        XCTAssertEqual(hydrated.status, .interrupted)
        XCTAssertEqual(hydrated.stopReason, .appInterrupted)
        XCTAssertNotNil(hydrated.endedAt)
        XCTAssertEqual(LoopRunTranscriptCodec.decode(from: reloadedStore.transcript(for: session.id)[0])?.status, .interrupted)
    }

    func testLegacyLoopRunJSONWithoutValidationCommandStillDecodes() throws {
        let sessionID = UUID()
        let run = LoopRun(
            sessionID: sessionID,
            projectPath: nil,
            draft: LoopDraft(goal: "Legacy", validationCommand: "/usr/bin/true")
        )
        let rawJSON = try XCTUnwrap(LoopRunTranscriptCodec.rawJSON(for: run))
        let data = try XCTUnwrap(rawJSON.data(using: .utf8))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "validationCommand")
        let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let legacyRawJSON = try XCTUnwrap(String(data: legacyData, encoding: .utf8))
        let entry = PiAgentTranscriptEntry(
            sessionID: sessionID,
            role: .status,
            title: LoopRunTranscriptCodec.title,
            text: "Loop",
            rawJSON: legacyRawJSON
        )

        let decoded = try XCTUnwrap(LoopRunTranscriptCodec.decode(from: entry))
        XCTAssertEqual(decoded.id, run.id)
        XCTAssertEqual(decoded.validationCommand, "")
    }

    func testLegacyLoopRunJSONWithoutLaunchContextFieldsStillDecodes() throws {
        let sessionID = UUID()
        let run = LoopRun(
            sessionID: sessionID,
            projectPath: nil,
            draft: LoopDraft(goal: "Legacy context", launchContext: "Context", launchContextScope: .everyIteration)
        )
        let rawJSON = try XCTUnwrap(LoopRunTranscriptCodec.rawJSON(for: run))
        let data = try XCTUnwrap(rawJSON.data(using: .utf8))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "launchContext")
        object.removeValue(forKey: "launchContextScope")
        let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let legacyRawJSON = try XCTUnwrap(String(data: legacyData, encoding: .utf8))
        let entry = PiAgentTranscriptEntry(
            sessionID: sessionID,
            role: .status,
            title: LoopRunTranscriptCodec.title,
            text: "Loop",
            rawJSON: legacyRawJSON
        )

        let decoded = try XCTUnwrap(LoopRunTranscriptCodec.decode(from: entry))
        XCTAssertEqual(decoded.id, run.id)
        XCTAssertNil(decoded.launchContext)
        XCTAssertEqual(decoded.launchContextScope, .firstIterationOnly)
    }

    func testPassingValidationCommandStopsFirstIteration() throws {
        let stateFile = PiTestSupport.temporaryStateFile()
        let projectURL = try PiTestSupport.temporaryProjectURL()
        let store = PiAgentSessionStore(fileURL: stateFile)
        let session = store.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(url: projectURL), repository: nil)

        let run = try XCTUnwrap(store.launchSmokeLoop(
            sessionID: session.id,
            projectPath: session.projectPath,
            draft: LoopDraft(goal: "Validate once", maxIterations: 3, validationCommand: "/usr/bin/true")
        ))

        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.stopReason, .success)
        XCTAssertEqual(run.currentIteration, 1)
        XCTAssertEqual(run.iterations.count, 1)
        XCTAssertEqual(run.iterations[0].validationResult?.exitCode, 0)
        let validation = try XCTUnwrap(run.iterations[0].validationResult)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(validation.stdoutPath)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(validation.stderrPath)))
    }

    func testFailingValidationRepeatsToMaxIterationsAndRecordsFinalStopReason() throws {
        let stateFile = PiTestSupport.temporaryStateFile()
        let projectURL = try PiTestSupport.temporaryProjectURL()
        let store = PiAgentSessionStore(fileURL: stateFile)
        let session = store.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(url: projectURL), repository: nil)

        let run = try XCTUnwrap(store.launchSmokeLoop(
            sessionID: session.id,
            projectPath: session.projectPath,
            draft: LoopDraft(goal: "Retry validation", maxIterations: 3, validationCommand: "/usr/bin/false")
        ))

        XCTAssertEqual(run.status, .notAchieved)
        XCTAssertEqual(run.stopReason, .validationFailedAfterFinalIteration)
        XCTAssertEqual(run.currentIteration, 3)
        XCTAssertEqual(run.iterations.count, 3)
        XCTAssertEqual(run.iterations.map { $0.validationResult?.exitCode }, [1, 1, 1])
        XCTAssertEqual(run.iterations.map { $0.artifacts.first?.filename }, ["loop-smoke.md", "loop-smoke-2.md", "loop-smoke-3.md"])
    }

    func testMissingValidationCommandRecordsValidationUnavailable() throws {
        let stateFile = PiTestSupport.temporaryStateFile()
        let projectURL = try PiTestSupport.temporaryProjectURL()
        let store = PiAgentSessionStore(fileURL: stateFile)
        let session = store.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(url: projectURL), repository: nil)

        let run = try XCTUnwrap(store.launchSmokeLoop(
            sessionID: session.id,
            projectPath: session.projectPath,
            draft: LoopDraft(goal: "No validation", maxIterations: 3)
        ))

        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(run.stopReason, .validationUnavailable)
        XCTAssertEqual(run.currentIteration, 1)
        XCTAssertEqual(run.iterations.count, 1)
        XCTAssertNil(run.iterations[0].validationResult?.exitCode)
        XCTAssertEqual(run.iterations[0].validationResult?.stderr, "Validation command is empty.")
    }

    func testMakerCheckerRunsMakerBeforeCheckerTimeline() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(), repository: nil)

        let run = try XCTUnwrap(store.launchSmokeLoop(
            sessionID: session.id,
            projectPath: session.projectPath,
            draft: LoopDraft(goal: "Review the artifact", structure: .makerChecker, makerChecker: LoopMakerCheckerConfig(makerName: "Maker A", checkerName: "Checker B", checkerRubric: "approve"))
        ))

        let iteration = try XCTUnwrap(run.iterations.first)
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(iteration.checkerResult, .approve)
        XCTAssertEqual(iteration.timeline.map(\.step), [.makerAct, .checkerReview])
        XCTAssertEqual(iteration.timeline.map(\.roleName), ["Maker A", "Checker B"])
        let makerTimestamp = try XCTUnwrap(iteration.timeline.first?.timestamp)
        let checkerTimestamp = try XCTUnwrap(iteration.timeline.last?.timestamp)
        XCTAssertTrue(makerTimestamp <= checkerTimestamp)
    }

    func testMakerCheckerApprovalStopsSuccessfully() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(), repository: nil)

        let run = try XCTUnwrap(store.launchSmokeLoop(
            sessionID: session.id,
            projectPath: session.projectPath,
            draft: LoopDraft(goal: "Approve immediately", structure: .makerChecker, maxIterations: 3, makerChecker: LoopMakerCheckerConfig(checkerRubric: "approve"))
        ))

        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.stopReason, .success)
        XCTAssertEqual(run.currentIteration, 1)
        XCTAssertEqual(run.iterations.map(\.checkerResult), [.approve])
    }

    func testMakerCheckerRejectionRevisesUntilApproved() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(), repository: nil)

        let run = try XCTUnwrap(store.launchSmokeLoop(
            sessionID: session.id,
            projectPath: session.projectPath,
            draft: LoopDraft(goal: "Revise once", structure: .makerChecker, maxIterations: 3, makerChecker: LoopMakerCheckerConfig(checkerRubric: "reject once then approve"))
        ))

        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.stopReason, .success)
        XCTAssertEqual(run.currentIteration, 2)
        XCTAssertEqual(run.iterations.map(\.checkerResult), [.reject, .approve])
        XCTAssertEqual(run.iterations.flatMap { $0.timeline.map(\.step) }, [.makerAct, .checkerReview, .makerAct, .checkerReview])
    }

    func testMakerCheckerAskHumanStopsForInput() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(), repository: nil)

        let run = try XCTUnwrap(store.launchSmokeLoop(
            sessionID: session.id,
            projectPath: session.projectPath,
            draft: LoopDraft(goal: "Needs decision", structure: .makerChecker, maxIterations: 3, makerChecker: LoopMakerCheckerConfig(checkerRubric: "ask human"))
        ))

        XCTAssertEqual(run.status, .stopped)
        XCTAssertEqual(run.stopReason, .humanInputRequired)
        XCTAssertEqual(run.currentIteration, 1)
        XCTAssertEqual(run.iterations.map(\.checkerResult), [.askHuman])
        XCTAssertNil(store.activeLoopRun(for: session.id))
    }

    func testAgentPipelineRecordsOrderedStageTimeline() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(), repository: nil)

        let run = try XCTUnwrap(store.launchSmokeLoop(
            sessionID: session.id,
            projectPath: session.projectPath,
            draft: LoopDraft(
                goal: "Pipeline preview",
                structure: .agentPipeline,
                validationCommand: "/usr/bin/true",
                pipeline: LoopPipelineConfig(stageNames: ["Explore", "Build", "Verify"])
            )
        ))

        let iteration = try XCTUnwrap(run.iterations.first)
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(iteration.timeline.map(\.step), [.pipelineStage, .pipelineStage, .pipelineStage])
        XCTAssertEqual(iteration.timeline.map(\.roleName), ["Explore", "Build", "Verify"])
        XCTAssertEqual(iteration.artifacts.first?.filename, "pipeline-summary.md")
    }

    func testParallelAgentsRecordsBranchesAndWorktreeKeepsCheckoutUntouched() throws {
        let stateFile = PiTestSupport.temporaryStateFile()
        let projectURL = try makeTemporaryGitRepository()
        let before = try projectEntries(at: projectURL)
        let store = PiAgentSessionStore(fileURL: stateFile)
        let session = store.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(url: projectURL), repository: nil)

        let run = try XCTUnwrap(store.launchSmokeLoop(
            sessionID: session.id,
            projectPath: session.projectPath,
            draft: LoopDraft(
                goal: "Parallel preview",
                structure: .parallelAgents,
                writeTarget: .newWorktree,
                validationCommand: "test -f loop-smoke-write-target.txt",
                parallel: LoopParallelConfig(branchNames: ["A", "B", "C"])
            )
        ))

        let iteration = try XCTUnwrap(run.iterations.first)
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(iteration.timeline.map(\.step), [.parallelBranch, .parallelBranch, .parallelBranch])
        XCTAssertEqual(iteration.timeline.map(\.roleName), ["A", "B", "C"])
        XCTAssertEqual(try projectEntries(at: projectURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("loop-smoke-write-target.txt").path))
        XCTAssertEqual(iteration.changedFiles, ["loop-smoke-write-target.txt"])
    }

    func testDiscoveryTriageRecordsClassificationArtifact() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(), repository: nil)

        let run = try XCTUnwrap(store.launchSmokeLoop(
            sessionID: session.id,
            projectPath: session.projectPath,
            draft: LoopDraft(
                goal: "Triage failures",
                structure: .discoveryTriage,
                validationCommand: "/usr/bin/true",
                discoveryTriage: LoopDiscoveryTriageConfig(classificationPrompt: "severity then owner")
            )
        ))

        let artifact = try XCTUnwrap(run.iterations.first?.artifacts.first)
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.iterations.first?.timeline.map(\.step), [.discoveryTriage])
        XCTAssertEqual(artifact.filename, "discovery-triage.md")
        XCTAssertTrue(artifact.markdown.contains("severity then owner"))
    }

    func testHumanApprovalStopsWithHumanInputCheckpoint() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(), repository: nil)

        let run = try XCTUnwrap(store.launchSmokeLoop(
            sessionID: session.id,
            projectPath: session.projectPath,
            draft: LoopDraft(
                goal: "Needs approval",
                structure: .humanApproval,
                validationCommand: "/usr/bin/true",
                humanApproval: LoopHumanApprovalConfig(checkpointPrompt: "Approve plan?")
            )
        ))

        XCTAssertEqual(run.status, .stopped)
        XCTAssertEqual(run.stopReason, .humanInputRequired)
        XCTAssertEqual(run.currentIteration, 1)
        XCTAssertEqual(run.iterations.first?.timeline.map(\.step), [.humanApprovalCheckpoint])
        XCTAssertEqual(run.iterations.first?.artifacts.first?.filename, "human-approval-checkpoint.md")
        XCTAssertNil(store.activeLoopRun(for: session.id))
    }

    func testAppViewModelLaunchLoopRoutesHumanApprovalCheckpoint() async throws {
        let viewModel = AppViewModel()
        let session = viewModel.piAgentSessionStore.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(), repository: nil)

        let launched = await viewModel.launchLoop(
            session: session,
            draft: LoopDraft(goal: "Needs approval", structure: .humanApproval),
            stopExistingActive: false
        )
        let run = try XCTUnwrap(launched)

        XCTAssertEqual(run.structure, .humanApproval)
        XCTAssertEqual(run.status, .stopped)
        XCTAssertEqual(run.stopReason, .humanInputRequired)
        XCTAssertEqual(run.iterations.first?.timeline.map(\.step), [.humanApprovalCheckpoint])
    }

    func testHumanApprovalCanBeApprovedOrRejectedFromCheckpoint() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(), repository: nil)

        let approvedCheckpoint = try XCTUnwrap(store.launchSmokeLoop(
            sessionID: session.id,
            projectPath: session.projectPath,
            draft: LoopDraft(goal: "Approve me", structure: .humanApproval)
        ))
        let approved = try XCTUnwrap(store.resolveHumanApprovalLoopRun(approvedCheckpoint.id, sessionID: session.id, approved: true))
        XCTAssertEqual(approved.status, .stopped)
        XCTAssertEqual(approved.stopReason, .humanApproved)
        XCTAssertEqual(approved.currentIteration, 2)
        XCTAssertEqual(approved.iterations.last?.summary, "Human approval recorded. Start a new attempt for follow-up work.")

        let rejectedCheckpoint = try XCTUnwrap(store.launchSmokeLoop(
            sessionID: session.id,
            projectPath: session.projectPath,
            draft: LoopDraft(goal: "Reject me", structure: .humanApproval)
        ))
        let rejected = try XCTUnwrap(store.resolveHumanApprovalLoopRun(rejectedCheckpoint.id, sessionID: session.id, approved: false))
        XCTAssertEqual(rejected.status, .stopped)
        XCTAssertEqual(rejected.stopReason, .humanRejected)
        XCTAssertEqual(rejected.currentIteration, 2)
        XCTAssertEqual(rejected.iterations.last?.summary, "Human rejected checkpoint.")
    }

    private func projectEntries(at url: URL) throws -> [String] {
        let root = url.standardizedFileURL
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var entries: [String] = []
        for case let fileURL as URL in enumerator {
            let relative = String(fileURL.standardizedFileURL.path.dropFirst(root.path.count + 1))
            if relative == ".git" || relative.hasPrefix(".git/") {
                enumerator.skipDescendants()
                continue
            }
            entries.append(relative)
        }
        return entries.sorted()
    }

    private func makeTemporaryGitRepository() throws -> URL {
        let projectURL = try PiTestSupport.temporaryProjectURL()
        try "hello\n".write(to: projectURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runShell("git init && git config user.email test@example.com && git config user.name Test && git add README.md && git commit -m initial", in: projectURL)
        return projectURL
    }

    private func runShell(_ command: String, in directory: URL) throws {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = directory
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTFail(message)
        }
    }

    private func path(_ path: String, isUnder parentPath: String) -> Bool {
        let child = URL(fileURLWithPath: path).standardizedFileURL.path
        let parent = URL(fileURLWithPath: parentPath).standardizedFileURL.path
        return child == parent || child.hasPrefix(parent + "/")
    }

    func testActiveLoopBlocksSecondLaunchUnlessStopFirst() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = store.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(), repository: nil)
        let active = LoopRun(sessionID: session.id, projectPath: session.projectPath, draft: LoopDraft(goal: "Active"))
        store.upsert(.init(
            id: active.transcriptEntryID,
            sessionID: session.id,
            role: .status,
            title: LoopRunTranscriptCodec.title,
            text: LoopRunTranscriptCodec.transcriptText(for: active),
            rawJSON: LoopRunTranscriptCodec.rawJSON(for: active)
        ))
        store.hydrateLoopRunsFromTranscript(sessionID: session.id)

        XCTAssertNil(store.launchSmokeLoop(sessionID: session.id, projectPath: session.projectPath, draft: LoopDraft(goal: "Second")))
        XCTAssertNotNil(store.activeLoopRun(for: session.id))

        let second = try XCTUnwrap(store.launchSmokeLoop(sessionID: session.id, projectPath: session.projectPath, draft: LoopDraft(goal: "Second", validationCommand: "/usr/bin/true"), stopExistingActive: true))
        XCTAssertEqual(second.status, .completed)
        XCTAssertNil(store.activeLoopRun(for: session.id))
        XCTAssertTrue(store.loopRuns(for: session.id).contains { $0.id == active.id && $0.stopReason == .userStopped })
    }
}
