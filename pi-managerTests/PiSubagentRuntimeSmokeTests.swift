import XCTest
@testable import pi_manager

final class PiSubagentLaunchPlannerTests: XCTestCase {
    func testDefaultAgentInheritsParentProviderModelAndThinking() throws {
        let selection = PiSubagentLaunchPlanner.modelSelection(
            for: PiTestSupport.makeAgent(model: nil, thinking: nil),
            parentSession: try PiTestSupport.makeParentSession(model: "glm-5.1", provider: "zai", thinking: "low")
        )

        XCTAssertEqual(selection.provider, "zai")
        XCTAssertEqual(selection.modelArgument, "glm-5.1:low")
        XCTAssertEqual(selection.displayName, "zai/glm-5.1:low")
    }

    func testExplicitAgentModelWinsOverParentModel() throws {
        let selection = PiSubagentLaunchPlanner.modelSelection(
            for: PiTestSupport.makeAgent(model: "openai-codex/gpt-5.5", thinking: "high"),
            parentSession: try PiTestSupport.makeParentSession(model: "glm-5.1", provider: "zai", thinking: "low")
        )

        XCTAssertNil(selection.provider)
        XCTAssertEqual(selection.modelArgument, "openai-codex/gpt-5.5:high")
        XCTAssertEqual(selection.displayName, "openai-codex/gpt-5.5:high")
    }

    func testThinkingSuffixIsNotDuplicated() throws {
        let selection = PiSubagentLaunchPlanner.modelSelection(
            for: PiTestSupport.makeAgent(model: nil, thinking: nil),
            parentSession: try PiTestSupport.makeParentSession(model: "glm-5.1:low", provider: "zai", thinking: "low")
        )

        XCTAssertEqual(selection.provider, "zai")
        XCTAssertEqual(selection.modelArgument, "glm-5.1:low")
        XCTAssertEqual(selection.displayName, "zai/glm-5.1:low")
    }

    func testInheritedLaunchArgumentsIncludeProviderAndModel() throws {
        let selection = PiSubagentLaunchPlanner.modelSelection(
            for: PiTestSupport.makeAgent(model: nil, thinking: nil),
            parentSession: try PiTestSupport.makeParentSession(model: "glm-5.1", provider: "zai", thinking: "low")
        )

        let arguments = PiRPCClient.launchArguments(
            provider: selection.provider,
            modelArgument: selection.modelArgument,
            extraArguments: ["--session-dir", "/tmp/pi-manager-test-session"]
        )

        XCTAssertEqual(arguments, [
            "--mode", "rpc",
            "--session-dir", "/tmp/pi-manager-test-session",
            "--provider", "zai",
            "--model", "glm-5.1:low"
        ])
    }

    func testForkContextRequiresParentSessionFile() throws {
        let agent = PiTestSupport.makeAgent(defaultContext: "fork")

        XCTAssertEqual(
            PiSubagentLaunchPlanner.resolvedContextMode(for: agent, parentSession: try PiTestSupport.makeParentSession(piSessionFile: nil), requestedContext: .fork),
            .fresh
        )
        XCTAssertEqual(
            PiSubagentLaunchPlanner.resolvedContextMode(for: agent, parentSession: try PiTestSupport.makeParentSession(piSessionFile: "/tmp/parent.jsonl"), requestedContext: .agentDefault),
            .fork
        )
    }
}

@MainActor
final class PiSubagentRunServiceSmokeTests: XCTestCase {
    func testRunSingleCreatesArtifactsAndRecordsResolvedModelBeforeProcessEvents() throws {
        let fakePi = try PiTestSupport.makeFakePiExecutable()
        let oldPiPath = getenv("PI_MANAGER_PI_PATH").map { String(cString: $0) }
        setenv("PI_MANAGER_PI_PATH", fakePi.path, 1)
        defer { restorePiPath(oldPiPath) }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession(model: "glm-5.1", provider: "zai", thinking: "low")

        let run = try runner.runSingle(
            parentSession: parent,
            agent: PiTestSupport.makeAgent(model: nil, thinking: nil),
            snapshot: .empty,
            task: "report current directory",
            requestedContext: .fresh
        )
        defer { runner.stop(runID: run.id, parentSessionID: parent.id) }

        XCTAssertEqual(run.model, "zai/glm-5.1:low")
        XCTAssertEqual(run.child?.model, "zai/glm-5.1:low")
        XCTAssertTrue(run.launchCommand?.contains("--provider zai") == true)
        XCTAssertTrue(run.launchCommand?.contains("--model glm-5.1:low") == true)

        let artifactDirectory = try XCTUnwrap(run.artifactDirectory).asFileURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactDirectory.appendingPathComponent("input.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactDirectory.appendingPathComponent("system-prompt.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactDirectory.appendingPathComponent("output.md").path))

        let persisted = store.subagentRuns(for: parent.id).first(where: { $0.id == run.id })
        XCTAssertEqual(persisted?.model, "zai/glm-5.1:low")
    }

    func testReadFirstPathsRejectAbsoluteAndParentTraversalInputs() throws {
        let fakePi = try PiTestSupport.makeFakePiExecutable()
        let oldPiPath = getenv("PI_MANAGER_PI_PATH").map { String(cString: $0) }
        setenv("PI_MANAGER_PI_PATH", fakePi.path, 1)
        defer { restorePiPath(oldPiPath) }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession()

        let run = try runner.runSingle(
            parentSession: parent,
            agent: PiTestSupport.makeAgent(defaultReads: ["README.md", "/etc/passwd", "../secret.txt"]),
            snapshot: .empty,
            task: "Read allowed files only.",
            requestedContext: .fresh,
            readFirstPaths: ["pi-manager/AppViewModel.swift", "/tmp/nope", "../../outside"]
        )
        defer { runner.stop(runID: run.id, parentSessionID: parent.id) }

        XCTAssertEqual(run.readFirstPaths, ["README.md", "pi-manager/AppViewModel.swift"])
        let input = try String(contentsOf: try XCTUnwrap(run.artifactDirectory).asFileURL.appendingPathComponent("input.md"), encoding: .utf8)
        XCTAssertTrue(input.contains("README.md"))
        XCTAssertTrue(input.contains("pi-manager/AppViewModel.swift"))
        XCTAssertFalse(input.contains("/etc/passwd"))
        XCTAssertFalse(input.contains("../secret.txt"))
    }

    func testForkedRunUsesSanitizedReferenceSessionInArtifactDirectory() throws {
        let fakePi = try PiTestSupport.makeFakePiExecutable()
        let oldPiPath = getenv("PI_MANAGER_PI_PATH").map { String(cString: $0) }
        setenv("PI_MANAGER_PI_PATH", fakePi.path, 1)
        defer { restorePiPath(oldPiPath) }

        let parentSessionFile = try PiTestSupport.makeParentSessionFileWithActiveManagedSubagentCall()
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession(piSessionFile: parentSessionFile.path)

        let run = try runner.runSingle(
            parentSession: parent,
            agent: PiTestSupport.makeAgent(),
            snapshot: .empty,
            task: "Say whether you were launched with forked context.",
            requestedContext: .fork
        )
        defer { runner.stop(runID: run.id, parentSessionID: parent.id) }

        let artifactDirectory = try XCTUnwrap(run.artifactDirectory).asFileURL
        let forkContext = try String(contentsOf: artifactDirectory.appendingPathComponent("fork-context.jsonl"), encoding: .utf8)

        XCTAssertEqual(run.resolvedContext, .fork)
        XCTAssertTrue(run.launchCommand?.contains("--fork") == true)
        XCTAssertFalse(run.launchCommand?.contains(parentSessionFile.path) == true)
        XCTAssertTrue(forkContext.contains("Earlier useful context"))
        XCTAssertTrue(forkContext.contains("Pi Manager native subagent boundary"))
        XCTAssertFalse(forkContext.contains("Use managed_subagent with agent scout"))
        XCTAssertFalse(forkContext.contains("\"name\":\"managed_subagent\""))
    }

    func testLaunchCommandIsolatesChildPiFromAmbientExtensionsContextAndSkills() throws {
        let customExtension = "/tmp/pi-manager-custom-extension.ts"
        let harness = try PiTestSupport.makeBridgeHarness(events: [])
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession()

        let run = try runner.runSingle(
            parentSession: parent,
            agent: PiTestSupport.makeAgent(
                tools: ["shell", "contact_supervisor"],
                extensions: [customExtension],
                inheritProjectContext: false,
                inheritSkills: false
            ),
            snapshot: .empty,
            task: "Check isolation flags.",
            requestedContext: .fresh
        )
        defer { runner.stop(runID: run.id, parentSessionID: parent.id) }

        let command = try XCTUnwrap(run.launchCommand)
        XCTAssertTrue(command.contains("--no-context-files"))
        XCTAssertTrue(command.contains("--no-skills"))
        XCTAssertTrue(command.contains("--no-extensions"))
        XCTAssertTrue(command.contains("--extension"))
        XCTAssertTrue(command.contains("contact-supervisor-bridge.ts"))
        XCTAssertTrue(command.contains(customExtension))
        XCTAssertTrue(command.contains("--tools shell,contact_supervisor"))
        XCTAssertEqual(run.tools, ["shell", "contact_supervisor"])
    }

    func testExpectedOutcomePromptContractsAreSentToChildPi() throws {
        let reportOnly = try promptSentForOutcome(.reportOnly)
        XCTAssertTrue(reportOnly.contains("Expected outcome: Report only"))
        XCTAssertTrue(reportOnly.contains("Do not create, edit, delete, or overwrite project files."))

        let worktree = try promptSentForOutcome(.editFilesInWorktree)
        XCTAssertTrue(worktree.contains("Expected outcome: Edit files in worktree"))
        XCTAssertTrue(worktree.contains("Edit project files only in the current isolated worktree."))
        XCTAssertTrue(worktree.contains("Pi Manager will review/apply/discard the worktree diff."))

        let projectFile = try promptSentForOutcome(.writeProjectFile, requestedOutputPath: "docs/result.md")
        XCTAssertTrue(projectFile.contains("Expected outcome: Write/update project file"))
        XCTAssertTrue(projectFile.contains("Write/update exactly this project-relative output file: docs/result.md."))
        XCTAssertTrue(projectFile.contains("Overwrite policy: do not overwrite an existing file"))

        let directWrites = try promptSentForOutcome(.directProjectWrites)
        XCTAssertTrue(directWrites.contains("Expected outcome: Direct project writes"))
        XCTAssertTrue(directWrites.contains("Direct project writes were explicitly allowed by the user for this run."))
        XCTAssertTrue(directWrites.contains("mention every changed path in the final response."))
    }

    func testChildSupervisorProgressUpdateIsAcknowledgedWithoutBlockingRun() throws {
        let harness = try PiTestSupport.makeBridgeHarness(event: PiRPCBridgeFixtures.childSupervisor(id: "child-progress-1", requestKind: "progress_update", title: "Progress", message: "Half done."))
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession()

        let run = try runner.runSingle(
            parentSession: parent,
            agent: PiTestSupport.makeAgent(tools: ["contact_supervisor"]),
            snapshot: .empty,
            task: "Report progress.",
            requestedContext: .fresh
        )
        defer { runner.stop(runID: run.id, parentSessionID: parent.id) }

        XCTAssertTrue(PiTestSupport.waitUntil {
            PiTestSupport.extensionUIResponses(in: harness.stdinLog).contains { $0["id"] as? String == "child-progress-1" }
        })
        let request = try XCTUnwrap(store.supervisorRequests(for: parent.id).first)
        XCTAssertEqual(request.kind, .progressUpdate)
        XCTAssertEqual(request.status, .answered)
        XCTAssertEqual(PiTestSupport.extensionUIResponses(in: harness.stdinLog).first?["value"] as? String, "Acknowledged.")
    }

    func testChildSupervisorNeedDecisionBlocksRunUntilAnswered() throws {
        let harness = try PiTestSupport.makeBridgeHarness(event: PiRPCBridgeFixtures.childSupervisor(id: "child-decision-1", requestKind: "need_decision", title: "Decision", message: "Choose path."))
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession()

        let run = try runner.runSingle(
            parentSession: parent,
            agent: PiTestSupport.makeAgent(tools: ["contact_supervisor"]),
            snapshot: .empty,
            task: "Ask for decision.",
            requestedContext: .fresh
        )
        defer { runner.stop(runID: run.id, parentSessionID: parent.id) }

        XCTAssertTrue(PiTestSupport.waitUntil { store.supervisorRequests(for: parent.id).first?.status == .pending })
        let request = try XCTUnwrap(store.supervisorRequests(for: parent.id).first)
        XCTAssertEqual(request.kind, .needDecision)
        XCTAssertEqual(store.subagentRuns(for: parent.id).first(where: { $0.id == run.id })?.status, .blocked)

        runner.respondToSupervisorRequest(request.id, parentSessionID: parent.id, response: "Use worktree.")

        XCTAssertTrue(PiTestSupport.waitUntil { responseValue(id: "child-decision-1", in: harness.stdinLog) == "Use worktree." })
        XCTAssertEqual(store.supervisorRequests(for: parent.id).first?.status, .answered)
        XCTAssertEqual(store.supervisorRequests(for: parent.id).first?.response, "Use worktree.")
    }

    func testChildSupervisorInterviewRequestBlocksRunUntilAnswered() throws {
        let harness = try PiTestSupport.makeBridgeHarness(event: PiRPCBridgeFixtures.childSupervisor(id: "child-interview-1", requestKind: "interview_request", title: "Interview", message: "Need user interview."))
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession()

        let run = try runner.runSingle(
            parentSession: parent,
            agent: PiTestSupport.makeAgent(tools: ["contact_supervisor"]),
            snapshot: .empty,
            task: "Ask to interview the user.",
            requestedContext: .fresh
        )
        defer { runner.stop(runID: run.id, parentSessionID: parent.id) }

        XCTAssertTrue(PiTestSupport.waitUntil { store.supervisorRequests(for: parent.id).first?.status == .pending })
        let request = try XCTUnwrap(store.supervisorRequests(for: parent.id).first)
        XCTAssertEqual(request.kind, .interviewRequest)
        XCTAssertEqual(store.subagentRuns(for: parent.id).first(where: { $0.id == run.id })?.status, .blocked)

        runner.respondToSupervisorRequest(request.id, parentSessionID: parent.id, response: "Schedule a focused interview.")

        XCTAssertTrue(PiTestSupport.waitUntil { responseValue(id: "child-interview-1", in: harness.stdinLog) == "Schedule a focused interview." })
        XCTAssertEqual(store.supervisorRequests(for: parent.id).first?.status, .answered)
    }

    private func responseValue(id: String, in logURL: URL) -> String? {
        PiTestSupport.extensionUIResponses(in: logURL).first { $0["id"] as? String == id }?["value"] as? String
    }

    private func promptSentForOutcome(
        _ expectedOutcome: PiSubagentExpectedOutcome,
        requestedOutputPath: String? = nil
    ) throws -> String {
        let harness = try PiTestSupport.makeBridgeHarness(events: [])
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession()
        let run = try runner.runSingle(
            parentSession: parent,
            agent: PiTestSupport.makeAgent(output: "docs/advisory.md"),
            snapshot: .empty,
            task: "Produce the requested outcome.",
            requestedContext: .fresh,
            expectedOutcome: expectedOutcome,
            requestedOutputPath: requestedOutputPath,
            allowOverwrite: false
        )
        defer { runner.stop(runID: run.id, parentSessionID: parent.id) }

        XCTAssertTrue(PiTestSupport.waitUntil {
            guard let log = try? String(contentsOf: harness.stdinLog, encoding: .utf8) else { return false }
            return log.contains("Expected outcome")
        })
        return try String(contentsOf: harness.stdinLog, encoding: .utf8)
    }

    private func restorePiPath(_ oldPiPath: String?) {
        if let oldPiPath {
            setenv("PI_MANAGER_PI_PATH", oldPiPath, 1)
        } else {
            unsetenv("PI_MANAGER_PI_PATH")
        }
    }
}

private extension String {
    var asFileURL: URL {
        URL(fileURLWithPath: self)
    }
}
