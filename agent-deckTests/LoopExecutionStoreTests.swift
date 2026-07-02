import XCTest
@testable import agent_deck

@MainActor
final class LoopExecutionStoreTests: XCTestCase {
    func testSingleAgentLoopCompletesOnValidationSuccess() async throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = try makeSession(store: store)
        var observedAgent = ""
        var observedWriteTarget: LoopWriteTarget?
        var observedOutputPath: String?
        var observedTask = ""
        let draft = LoopDraft(
            goal: "Produce report",
            structure: .singleAgent,
            writeTarget: .artifactMarkdown,
            validationCommand: "/usr/bin/true",
            makerChecker: LoopMakerCheckerConfig(makerName: "Explorer")
        )

        let maybeRun = await store.launchSingleAgentLoop(session: session, draft: draft) { _, agentName, task, writeTarget, _, outputPath in
            observedAgent = agentName
            observedWriteTarget = writeTarget
            observedOutputPath = outputPath
            observedTask = task
            return Self.fakeRun(parentSessionID: session.id, agentName: agentName, task: task, status: .completed, summary: "done")
        }
        let run = try XCTUnwrap(maybeRun)

        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.stopReason, .success)
        XCTAssertEqual(run.currentIteration, 1)
        XCTAssertEqual(run.iterations.count, 1)
        XCTAssertEqual(run.iterations[0].timeline.map(\.step), [.makerAct])
        XCTAssertEqual(run.iterations[0].timeline.map(\.roleName), ["Explorer"])
        XCTAssertEqual(run.iterations[0].artifacts.first?.filename, "single-agent-summary.md")
        XCTAssertEqual(observedAgent, "Explorer")
        XCTAssertEqual(observedWriteTarget, .artifactMarkdown)
        XCTAssertNotNil(observedOutputPath)
        XCTAssertTrue(observedTask.contains("Agent Deck controls iteration count, retries, stopping, artifacts, and validation"))
        XCTAssertTrue(observedTask.contains("Do not run your own open-ended loop"))
        XCTAssertTrue(observedTask.contains("You are completing one implementation/review pass"))
    }

    func testLaunchContextInjectionRespectsScope() async throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = try makeSession(store: store)
        var tasks: [String] = []
        let draft = LoopDraft(
            goal: "Use context",
            launchContext: "Secret launch notes\nSecond line",
            launchContextScope: .firstIterationOnly,
            structure: .singleAgent,
            maxIterations: 2,
            validationCommand: "/usr/bin/false",
            makerChecker: LoopMakerCheckerConfig(makerName: "Explorer")
        )

        _ = await store.launchSingleAgentLoop(session: session, draft: draft) { _, agentName, task, _, _, _ in
            tasks.append(task)
            return Self.fakeRun(parentSessionID: session.id, agentName: agentName, task: task, status: .completed, summary: "done")
        }

        XCTAssertEqual(tasks.count, 2)
        XCTAssertTrue(tasks[0].contains("Launch context (first iteration only):\nSecret launch notes\nSecond line"))
        XCTAssertFalse(tasks[1].contains("Launch context (first iteration only):\nSecret launch notes"))
    }

    func testLoopProgressFileCreatedAndSeededWithAndWithoutLaunchContext() async throws {
        let contextStore = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let contextSession = try makeSession(store: contextStore)
        let maybeContextRun = await contextStore.launchSingleAgentLoop(
            session: contextSession,
            draft: LoopDraft(
                goal: "Seed memory",
                launchContext: "Investigate flaky save path\nAvoid stale cache assumption",
                structure: .singleAgent,
                validationCommand: "/usr/bin/true",
                makerChecker: LoopMakerCheckerConfig(makerName: "Explorer")
            )
        ) { _, agentName, task, _, _, _ in
            XCTAssertTrue(task.contains("Shared loop progress file:"))
            XCTAssertTrue(task.contains("Agent Deck maintains `loop-progress.md`"))
            XCTAssertTrue(task.contains("## Launch Context Notes"))
            return Self.fakeRun(parentSessionID: contextSession.id, agentName: agentName, task: task, status: .completed, summary: "seeded")
        }
        let contextRun = try XCTUnwrap(maybeContextRun)
        let contextProgress = try progressText(for: contextRun)
        XCTAssertTrue(contextProgress.contains("## Goal\nSeed memory"))
        XCTAssertTrue(contextProgress.contains("## Launch Context Notes"))
        XCTAssertTrue(contextProgress.contains("Investigate flaky save path"))
        XCTAssertTrue(contextProgress.contains("## Round Notes"))
        XCTAssertTrue(contextProgress.contains("Round 1"))
        let progressPath = URL(fileURLWithPath: try XCTUnwrap(contextRun.artifactDirectoryPath)).appendingPathComponent("loop-progress.md").path
        XCTAssertFalse(path(progressPath, isUnder: try XCTUnwrap(contextSession.projectPath)))

        let plainStore = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let plainSession = try makeSession(store: plainStore)
        let maybePlainRun = await plainStore.launchSingleAgentLoop(
            session: plainSession,
            draft: LoopDraft(goal: "No context", structure: .singleAgent, validationCommand: "/usr/bin/true", makerChecker: LoopMakerCheckerConfig(makerName: "Explorer"))
        ) { _, agentName, task, _, _, _ in
            XCTAssertTrue(task.contains("Shared loop progress file:"))
            XCTAssertFalse(task.contains("## Launch Context Notes"))
            return Self.fakeRun(parentSessionID: plainSession.id, agentName: agentName, task: task, status: .completed, summary: "plain")
        }
        let plainRun = try XCTUnwrap(maybePlainRun)
        let plainProgress = try progressText(for: plainRun)
        XCTAssertFalse(plainProgress.contains("## Launch Context Notes"))
    }

    func testLoopProgressFileUpdatesAfterMakerCheckerVerdictAndStaysBounded() async throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = try makeSession(store: store)
        let longMakerSummary = String(repeating: "Maker changed risky thing with extensive detail. ", count: 80)
        var responses = [longMakerSummary, "REJECT\nMissing concrete validation evidence for the risky change.", "Maker added validation evidence.", "APPROVE\nEvidence now satisfies the rubric."]
        var checkerTask = ""
        let maybeRun = await store.launchMakerCheckerLoop(
            session: session,
            draft: LoopDraft(
                goal: "Bounded maker checker memory",
                structure: .makerChecker,
                validationCommand: "/usr/bin/true",
                makerChecker: LoopMakerCheckerConfig(makerName: "Builder", checkerName: "Reviewer", checkerRubric: "approve")
            )
        ) { _, role, task, _, _, _ in
            if role == "Reviewer" { checkerTask = task }
            return Self.fakeRun(parentSessionID: session.id, agentName: role, task: task, status: .completed, summary: responses.removeFirst())
        }

        let run = try XCTUnwrap(maybeRun)
        let progress = try progressText(for: run)
        XCTAssertTrue(checkerTask.contains("Shared loop progress file:"))
        XCTAssertTrue(progress.contains("Checker outcome: Approve") || progress.contains("checker approved"))
        XCTAssertTrue(progress.contains("Missing concrete validation evidence"))
        XCTAssertTrue(progress.contains("Do not repeat Round 1 rejection cause"))
        XCTAssertLessThan(progress.count, 6_000)
        XCTAssertFalse(progress.contains(String(repeating: "Maker changed risky thing", count: 10)))
    }

    func testLoopProgressFileUpdatesForPipelineAndParallelPromptsMergeAfterGraph() async throws {
        let pipelineStore = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let pipelineSession = try makeSession(store: pipelineStore)
        var pipelineTasks: [String] = []
        let maybePipelineRun = await pipelineStore.launchAgentPipelineLoop(
            session: pipelineSession,
            draft: LoopDraft(goal: "Pipeline memory", structure: .agentPipeline, validationCommand: "/usr/bin/true", pipeline: LoopPipelineConfig(stageNames: ["Analyze", "Implement"]))
        ) { _, role, task, _, _, _ in
            pipelineTasks.append(task)
            return Self.fakeRun(parentSessionID: pipelineSession.id, agentName: role, task: task, status: .completed, summary: "\(role) summary")
        }
        let pipelineRun = try XCTUnwrap(maybePipelineRun)
        XCTAssertEqual(pipelineTasks.count, 2)
        XCTAssertTrue(pipelineTasks.allSatisfy { $0.contains("Shared loop progress file:") })
        let pipelineProgress = try progressText(for: pipelineRun)
        XCTAssertTrue(pipelineProgress.contains("Stage 1 — Analyze"))
        XCTAssertTrue(pipelineProgress.contains("Stage 2 — Implement"))

        let parallelStore = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let parallelSession = try makeSession(store: parallelStore)
        var parallelTasks: [(String, String)] = []
        let maybeParallelRun = await parallelStore.launchParallelAgentsLoop(
            session: parallelSession,
            draft: LoopDraft(goal: "Parallel memory", structure: .parallelAgents, validationCommand: "/usr/bin/true", parallel: LoopParallelConfig(branchNames: ["A", "B"]))
        ) { _, tasks, _, _ in
            parallelTasks = tasks
            XCTAssertFalse(tasks.map(\.1).joined(separator: "\n").contains("A found one path"))
            return Self.fakeRun(parentSessionID: parallelSession.id, agentName: "Parallel", task: "parallel", mode: .parallel, status: .completed, summary: "A found one path; B found another path.")
        }
        let parallelRun = try XCTUnwrap(maybeParallelRun)
        XCTAssertEqual(parallelTasks.count, 2)
        XCTAssertTrue(parallelTasks.allSatisfy { $0.1.contains("Shared loop progress file:") })
        let parallelProgress = try progressText(for: parallelRun)
        XCTAssertTrue(parallelProgress.contains("A found one path"))
        XCTAssertTrue(parallelProgress.contains("artifacts parallel-summary.md"))
    }

    func testLoopSeparatorsIterationRecapsAndFinalRecapAreGeneratedAndDeduplicated() async throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = try makeSession(store: store)
        let draft = LoopDraft(
            goal: "Recap this",
            structure: .singleAgent,
            writeTarget: .artifactMarkdown,
            validationCommand: "/usr/bin/true",
            makerChecker: LoopMakerCheckerConfig(makerName: "Explorer")
        )

        let maybeRun = await store.launchSingleAgentLoop(session: session, draft: draft) { _, agentName, task, _, _, _ in
            Self.fakeRun(parentSessionID: session.id, agentName: agentName, task: task, status: .completed, summary: "done")
        }
        let run = try XCTUnwrap(maybeRun)

        let transcript = store.transcriptsBySessionID[session.id] ?? []
        let separators = transcript.compactMap { entry -> (PiAgentTranscriptEntry, LoopRunRecapMarker)? in
            guard let marker = LoopIterationSeparatorCodec.decode(from: entry) else { return nil }
            return (entry, marker)
        }
        let recaps = transcript.compactMap { entry -> (PiAgentTranscriptEntry, LoopRunRecapMarker)? in
            guard let marker = LoopRunRecapCodec.decode(from: entry) else { return nil }
            return (entry, marker)
        }
        XCTAssertEqual(separators.count, 1)
        XCTAssertEqual(separators.first?.1.kind, .iteration)
        XCTAssertTrue(separators.first?.0.text.contains("Iteration 1 of") == true)
        XCTAssertEqual(recaps.count, 2)
        XCTAssertEqual(recaps.filter { $0.1.kind == .iteration }.count, 1)
        XCTAssertEqual(recaps.filter { $0.1.kind == .final }.count, 1)
        XCTAssertTrue(recaps.contains { $0.0.text.contains("Round 1 recap") && $0.0.text.contains("done") && $0.0.text.contains("Validation: passed") })
        XCTAssertTrue(recaps.contains { $0.0.text.contains("Loop final recap") && $0.0.text.contains("Outcome: Success") })

        store.hydrateLoopRunsFromTranscript(sessionID: session.id)
        let afterHydrateRecaps = (store.transcriptsBySessionID[session.id] ?? []).compactMap(LoopRunRecapCodec.decode(from:))
        let afterHydrateSeparators = (store.transcriptsBySessionID[session.id] ?? []).compactMap(LoopIterationSeparatorCodec.decode(from:))
        XCTAssertEqual(afterHydrateRecaps.count, 2)
        XCTAssertEqual(afterHydrateRecaps.filter { $0.runID == run.id && $0.kind == .iteration }.count, 1)
        XCTAssertEqual(afterHydrateRecaps.filter { $0.runID == run.id && $0.kind == .final }.count, 1)
        XCTAssertEqual(afterHydrateSeparators.filter { $0.runID == run.id && $0.kind == .iteration }.count, 1)
    }

    func testSingleAgentLoopMapsChildFailureAndStop() async throws {
        let failedStore = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let failedSession = try makeSession(store: failedStore)
        let draft = LoopDraft(goal: "Run", structure: .singleAgent, validationCommand: "/usr/bin/true", makerChecker: LoopMakerCheckerConfig(makerName: "Explorer"))
        let maybeFailed = await failedStore.launchSingleAgentLoop(session: failedSession, draft: draft) { _, agentName, task, _, _, _ in
            Self.fakeRun(parentSessionID: failedSession.id, agentName: agentName, task: task, status: .failed, summary: "bad")
        }
        let failed = try XCTUnwrap(maybeFailed)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.stopReason, .agentFailed)

        let stoppedStore = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let stoppedSession = try makeSession(store: stoppedStore)
        let maybeStopped = await stoppedStore.launchSingleAgentLoop(session: stoppedSession, draft: draft) { _, agentName, task, _, _, _ in
            Self.fakeRun(parentSessionID: stoppedSession.id, agentName: agentName, task: task, status: .stopped, summary: "stopped")
        }
        let stopped = try XCTUnwrap(maybeStopped)
        XCTAssertEqual(stopped.status, .stopped)
        XCTAssertEqual(stopped.stopReason, .userStopped)
    }

    func testAgentPipelineLoopCompletesOnValidationSuccess() async throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = try makeSession(store: store)
        var observed: [(role: String, writeTarget: LoopWriteTarget, outputPath: String?)] = []
        let draft = LoopDraft(
            goal: "Fix ticket",
            structure: .agentPipeline,
            writeTarget: .artifactMarkdown,
            validationCommand: "/usr/bin/true",
            pipeline: LoopPipelineConfig(stageNames: ["Analyze", "Implement"])
        )

        let maybeRun = await store.launchAgentPipelineLoop(session: session, draft: draft) { _, role, task, writeTarget, _, outputPath in
            observed.append((role, writeTarget, outputPath))
            if role == "Analyze" {
                XCTAssertTrue(task.contains("You are completing stage 1 of 2 in an ordered pipeline"))
                XCTAssertTrue(task.contains("Do only the work appropriate for this assigned stage"))
            }
            return Self.fakeRun(parentSessionID: session.id, agentName: role, task: task, status: .completed, summary: "\(role) done")
        }
        let run = try XCTUnwrap(maybeRun)

        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.stopReason, .success)
        XCTAssertEqual(run.currentIteration, 1)
        XCTAssertEqual(run.iterations.count, 1)
        XCTAssertEqual(run.iterations[0].timeline.map(\.step), [.pipelineStage, .pipelineStage])
        XCTAssertEqual(run.iterations[0].timeline.map(\.roleName), ["Analyze", "Implement"])
        XCTAssertEqual(run.iterations[0].artifacts.first?.filename, "pipeline-summary.md")
        XCTAssertEqual(observed.map(\.role), ["Analyze", "Implement"])
        XCTAssertTrue(observed.allSatisfy { $0.writeTarget == .artifactMarkdown && $0.outputPath != nil })
    }

    func testAgentPipelineLoopStopsOnFailedStage() async throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = try makeSession(store: store)
        var calls: [String] = []
        let draft = LoopDraft(
            goal: "Fix ticket",
            structure: .agentPipeline,
            writeTarget: .artifactMarkdown,
            validationCommand: "/usr/bin/true",
            pipeline: LoopPipelineConfig(stageNames: ["Analyze", "Implement"])
        )

        let maybeRun = await store.launchAgentPipelineLoop(session: session, draft: draft) { _, role, task, _, _, _ in
            calls.append(role)
            let status: PiSubagentRunStatus = role == "Implement" ? .failed : .completed
            return Self.fakeRun(parentSessionID: session.id, agentName: role, task: task, status: status, summary: "\(role) result")
        }
        let run = try XCTUnwrap(maybeRun)

        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(run.stopReason, .agentFailed)
        XCTAssertEqual(run.currentIteration, 1)
        XCTAssertEqual(run.iterations.count, 1)
        XCTAssertNil(run.iterations[0].validationResult)
        XCTAssertEqual(run.iterations[0].timeline.map(\.roleName), ["Analyze", "Implement"])
        XCTAssertEqual(calls, ["Analyze", "Implement"])
    }

    func testParallelAgentsLoopCompletesWithGraphSuccess() async throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = try makeSession(store: store)
        var observedTasks: [(String, String)] = []
        var observedConcurrency = 0
        var observedUseWorktree = true
        let draft = LoopDraft(
            goal: "Compare options",
            structure: .parallelAgents,
            writeTarget: .artifactMarkdown,
            validationCommand: "/usr/bin/true",
            parallel: LoopParallelConfig(branchNames: ["BranchA", "BranchB"])
        )

        let maybeRun = await store.launchParallelAgentsLoop(session: session, draft: draft) { _, tasks, concurrency, useWorktree in
            observedTasks = tasks
            observedConcurrency = concurrency
            observedUseWorktree = useWorktree
            return Self.fakeRun(parentSessionID: session.id, agentName: "Parallel", task: "parallel", mode: .parallel, status: .completed, summary: "all done")
        }
        let run = try XCTUnwrap(maybeRun)

        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.stopReason, .success)
        XCTAssertEqual(run.currentIteration, 1)
        XCTAssertEqual(run.iterations.count, 1)
        XCTAssertEqual(run.iterations[0].timeline.map(\.step), [.parallelBranch, .parallelBranch])
        XCTAssertEqual(run.iterations[0].timeline.map(\.roleName), ["BranchA", "BranchB"])
        XCTAssertEqual(run.iterations[0].artifacts.first?.filename, "parallel-summary.md")
        XCTAssertEqual(observedTasks.map(\.0), ["BranchA", "BranchB"])
        XCTAssertTrue(observedTasks[0].1.contains("one assigned branch/hypothesis"))
        XCTAssertTrue(observedTasks[0].1.contains("Do not coordinate with sibling branches"))
        XCTAssertEqual(observedConcurrency, 2)
        XCTAssertFalse(observedUseWorktree)
    }

    func testDiscoveryTriageLoopCompletesWithConfiguredAgent() async throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = try makeSession(store: store)
        var observedAgent = ""
        var observedTask = ""
        let draft = LoopDraft(
            goal: "Triage failures",
            structure: .discoveryTriage,
            writeTarget: .artifactMarkdown,
            validationCommand: "/usr/bin/true",
            discoveryTriage: LoopDiscoveryTriageConfig(agentName: "Triage Agent", classificationPrompt: "severity and owner")
        )

        let maybeRun = await store.launchDiscoveryTriageLoop(session: session, draft: draft) { _, agentName, task, _, _, _ in
            observedAgent = agentName
            observedTask = task
            return Self.fakeRun(parentSessionID: session.id, agentName: agentName, task: task, status: .completed, summary: "triaged")
        }
        let run = try XCTUnwrap(maybeRun)

        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.stopReason, .success)
        XCTAssertEqual(run.iterations.count, 1)
        XCTAssertEqual(run.iterations[0].timeline.first?.step, .discoveryTriage)
        XCTAssertEqual(run.iterations[0].timeline.first?.roleName, "Triage Agent")
        XCTAssertEqual(run.iterations[0].artifacts.first?.filename, "discovery-triage-summary.md")
        XCTAssertEqual(observedAgent, "Triage Agent")
        XCTAssertTrue(observedTask.contains("Triage failures"))
        XCTAssertTrue(observedTask.contains("severity and owner"))
        XCTAssertTrue(observedTask.contains("performing discovery and triage"))
        XCTAssertTrue(observedTask.contains("Do not implement fixes unless the loop goal explicitly asks"))
        XCTAssertTrue(observedTask.contains("Shared loop progress file:"))
    }

    func testMakerCheckerLoopRejectThenApproveAcrossIterations() async throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = try makeSession(store: store)
        var responses = ["Maker pass", "REJECT\nMissing required evidence for the implementation.", "Maker revised", "APPROVE\nEvidence now satisfies the rubric."]
        var observedTasks: [(role: String, task: String)] = []
        let draft = LoopDraft(
            goal: "Build safely",
            structure: .makerChecker,
            writeTarget: .artifactMarkdown,
            maxIterations: 2,
            validationCommand: "/usr/bin/true",
            makerChecker: LoopMakerCheckerConfig(makerName: "Builder", checkerName: "Reviewer", checkerRubric: "approve")
        )

        let maybeRun = await store.launchMakerCheckerLoop(session: session, draft: draft) { _, role, task, _, _, _ in
            observedTasks.append((role, task))
            let summary = responses.removeFirst()
            return Self.fakeRun(parentSessionID: session.id, agentName: role, task: task, status: .completed, summary: summary)
        }
        let run = try XCTUnwrap(maybeRun)

        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.stopReason, .success)
        XCTAssertEqual(run.currentIteration, 2)
        XCTAssertEqual(run.iterations.count, 2)
        XCTAssertEqual(run.iterations.map(\.checkerResult), [.reject, .approve])
        XCTAssertEqual(run.iterations.flatMap { $0.timeline.map(\.step) }, [.makerAct, .checkerReview, .makerAct, .checkerReview])
        XCTAssertTrue(observedTasks[0].task.contains("implementing one maker pass"))
        XCTAssertTrue(observedTasks[1].task.contains("Agent Deck parses your first line"))
        XCTAssertTrue(observedTasks[1].task.contains("APPROVE, CONTINUE, REJECT, ASK_HUMAN, or FAIL"))
        XCTAssertTrue(observedTasks[1].task.contains("concise Markdown recap/rationale with concrete evidence"))
        XCTAssertTrue(run.iterations[0].summary.contains("Checker outcome: Reject"))
        XCTAssertTrue(run.iterations[0].summary.contains("Missing required evidence"))
        XCTAssertFalse(run.iterations[0].summary.contains("REJECT\n"))
        XCTAssertTrue(observedTasks[2].task.contains("Previous checker review to address"))
        XCTAssertTrue(responses.isEmpty)
    }

    func testMakerCheckerLoopContinueUsesIterationsWithoutRejectionSemantics() async throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = try makeSession(store: store)
        var responses = ["Maker pass", "CONTINUE\nAccepted first improvement; continue with the next high-impact target.", "Maker continued", "CONTINUE\nAccepted second improvement; no more iteration budget."]
        let draft = LoopDraft(
            goal: "Simplify safely",
            structure: .makerChecker,
            writeTarget: .artifactMarkdown,
            maxIterations: 2,
            validationCommand: "/usr/bin/true",
            makerChecker: LoopMakerCheckerConfig(makerName: "Builder", checkerName: "Reviewer", checkerRubric: "continue")
        )

        let maybeRun = await store.launchMakerCheckerLoop(session: session, draft: draft) { _, role, task, _, _, _ in
            let summary = responses.removeFirst()
            return Self.fakeRun(parentSessionID: session.id, agentName: role, task: task, status: .completed, summary: summary)
        }
        let run = try XCTUnwrap(maybeRun)

        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.stopReason, .maxIterationsReached)
        XCTAssertEqual(run.displayStatusName, "Completed")
        XCTAssertEqual(run.iterations.map(\.checkerResult), [.continueLoop, .continueLoop])
        let progress = try progressText(for: run)
        XCTAssertTrue(progress.contains("checker accepted and continued"))
        XCTAssertFalse(progress.contains("checker continue —"))
        XCTAssertFalse(LoopRunRecapCodec.finalText(for: run).contains("Goal not met"))
        XCTAssertTrue(LoopRunRecapCodec.finalText(for: run).contains("Final checker result: Continue"))
        XCTAssertTrue(responses.isEmpty)
    }

    func testMakerCheckerLoopMaxRejectsCompletesAsGoalNotMet() async throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = try makeSession(store: store)
        var responses = ["Maker pass", "REJECT\nThe first pass still misses the safety requirement.", "Maker revised", "REJECT\nThe final pass still lacks approval evidence."]
        let draft = LoopDraft(
            goal: "Build safely",
            structure: .makerChecker,
            writeTarget: .artifactMarkdown,
            maxIterations: 2,
            validationCommand: "/usr/bin/true",
            makerChecker: LoopMakerCheckerConfig(makerName: "Builder", checkerName: "Reviewer", checkerRubric: "approve")
        )

        let maybeRun = await store.launchMakerCheckerLoop(session: session, draft: draft) { _, role, task, _, _, _ in
            let summary = responses.removeFirst()
            return Self.fakeRun(parentSessionID: session.id, agentName: role, task: task, status: .completed, summary: summary)
        }
        let run = try XCTUnwrap(maybeRun)

        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.stopReason, .maxIterationsReached)
        XCTAssertEqual(run.displayStatusName, "Goal not met")
        XCTAssertEqual(run.currentIteration, 2)
        XCTAssertEqual(run.iterations.map(\.checkerResult), [.reject, .reject])
        XCTAssertTrue(LoopRunRecapCodec.finalText(for: run).contains("Loop final recap — Goal not met"))
        XCTAssertTrue(LoopRunRecapCodec.finalText(for: run).contains("Final checker result: Reject"))
        let finalText = try XCTUnwrap((store.transcriptsBySessionID[session.id] ?? []).first {
            LoopRunRecapCodec.decode(from: $0)?.kind == .final
        }?.text)
        XCTAssertTrue(finalText.contains("Loop outcome summary:"))
        XCTAssertTrue(finalText.contains("final pass still lacks approval evidence"))
        XCTAssertTrue(finalText.contains("Next Recommended Move:"))
        let recapEntries = (store.transcriptsBySessionID[session.id] ?? []).filter { LoopRunRecapCodec.decode(from: $0) != nil }
        XCTAssertEqual(recapEntries.filter { LoopRunRecapCodec.decode(from: $0)?.kind == .iteration }.count, 2)
        XCTAssertTrue(recapEntries.contains { $0.text.contains("Round 2 recap") && $0.text.contains("Checker outcome: Reject") && $0.text.contains("final pass still lacks approval evidence") })
        XCTAssertFalse(recapEntries.contains { $0.text.contains("Checker outcome: Failed") })
        XCTAssertTrue(responses.isEmpty)
    }

    func testMakerCheckerLoopCheckerRunFailureIsAgentFailureNotRejection() async throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = try makeSession(store: store)
        var responses = [(status: PiSubagentRunStatus, summary: String)]()
        responses.append((.completed, "Maker pass"))
        responses.append((.failed, "REJECT\nChecker process crashed before completing review."))
        let draft = LoopDraft(
            goal: "Build safely",
            structure: .makerChecker,
            writeTarget: .artifactMarkdown,
            validationCommand: "/usr/bin/true",
            makerChecker: LoopMakerCheckerConfig(makerName: "Builder", checkerName: "Reviewer", checkerRubric: "approve")
        )

        let maybeRun = await store.launchMakerCheckerLoop(session: session, draft: draft) { _, role, task, _, _, _ in
            let response = responses.removeFirst()
            return Self.fakeRun(parentSessionID: session.id, agentName: role, task: task, status: response.status, summary: response.summary)
        }
        let run = try XCTUnwrap(maybeRun)

        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(run.stopReason, .agentFailed)
        XCTAssertNil(run.iterations.first?.checkerResult)
        XCTAssertTrue(run.iterations[0].summary.contains("Checker stopped with failed"))
        XCTAssertTrue(responses.isEmpty)
    }

    func testMakerCheckerLoopExplicitCheckerFailIsFailed() async throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let session = try makeSession(store: store)
        var responses = ["Maker pass", "FAIL"]
        let draft = LoopDraft(
            goal: "Build safely",
            structure: .makerChecker,
            writeTarget: .artifactMarkdown,
            validationCommand: "/usr/bin/true",
            makerChecker: LoopMakerCheckerConfig(makerName: "Builder", checkerName: "Reviewer", checkerRubric: "approve")
        )

        let maybeRun = await store.launchMakerCheckerLoop(session: session, draft: draft) { _, role, task, _, _, _ in
            let summary = responses.removeFirst()
            return Self.fakeRun(parentSessionID: session.id, agentName: role, task: task, status: .completed, summary: summary)
        }
        let run = try XCTUnwrap(maybeRun)

        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(run.stopReason, .agentFailed)
        XCTAssertEqual(run.iterations.map(\.checkerResult), [.fail])
        XCTAssertFalse(run.presentsGoalNotMetOutcome)
        XCTAssertTrue(responses.isEmpty)
    }

}

private extension LoopExecutionStoreTests {
    func makeSession(store: PiAgentSessionStore) throws -> PiAgentSessionRecord {
        let projectURL = try PiTestSupport.temporaryProjectURL()
        return store.createSession(kind: .project, title: "Loop", project: try PiTestSupport.makeProject(url: projectURL), repository: nil)
    }

    private func progressText(for run: LoopRun) throws -> String {
        let artifactDirectoryPath = try XCTUnwrap(run.artifactDirectoryPath)
        let progressURL = URL(fileURLWithPath: artifactDirectoryPath, isDirectory: true).appendingPathComponent("loop-progress.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: progressURL.path))
        return try String(contentsOf: progressURL, encoding: .utf8)
    }

    private func path(_ path: String, isUnder parentPath: String) -> Bool {
        let child = URL(fileURLWithPath: path).standardizedFileURL.path
        let parent = URL(fileURLWithPath: parentPath).standardizedFileURL.path
        return child == parent || child.hasPrefix(parent + "/")
    }

    static func fakeRun(
        parentSessionID: UUID,
        agentName: String,
        task: String,
        mode: PiSubagentRunMode = .single,
        status: PiSubagentRunStatus,
        summary: String? = nil,
        error: String? = nil
    ) -> PiSubagentRunRecord {
        let now = Date()
        return PiSubagentRunRecord(
            id: UUID(), parentSessionID: parentSessionID, mode: mode, status: status,
            agentName: agentName, task: task,
            model: nil, thinking: nil, expectedOutcome: nil, requestedOutputPath: nil, allowOverwrite: nil, readFirstPaths: nil,
            tools: [], skills: [], concurrencyLimit: nil, worktreePolicy: nil, aggregateSummary: nil,
            artifactDirectory: "", outputPath: nil, worktreePath: nil, parentRepoPath: nil, baseCommit: nil,
            isWorktreeIsolated: nil, worktreeStatus: nil, worktreePatchPath: nil,
            childSessionID: nil, childPiSessionFile: nil, launchCommand: nil,
            summary: summary, error: error, child: nil, children: nil, graphEdges: nil,
            injectedMemoryIDs: nil, injectedMemoryTitles: nil,
            createdAt: now, updatedAt: now, completedAt: status.isActive ? nil : now, durationMs: 0
        )
    }
}
