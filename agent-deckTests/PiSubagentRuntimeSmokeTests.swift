import XCTest
@testable import agent_deck

final class PiSubagentLaunchPlannerTests: XCTestCase {
    @MainActor
    func testDefaultAgentInheritsParentProviderModelAndThinking() throws {
        let selection = PiSubagentLaunchPlanner.modelSelection(
            for: PiTestSupport.makeAgent(model: nil, thinking: nil),
            parentSession: try PiTestSupport.makeParentSession(model: "glm-5.1", provider: "zai", thinking: "low")
        )

        XCTAssertEqual(selection.provider, "zai")
        XCTAssertEqual(selection.modelArgument, "glm-5.1:low")
        XCTAssertEqual(selection.displayName, "zai/glm-5.1:low")
    }

    @MainActor
    func testExplicitAgentModelWinsOverParentModel() throws {
        let selection = PiSubagentLaunchPlanner.modelSelection(
            for: PiTestSupport.makeAgent(model: "openai-codex/gpt-5.5", thinking: "high"),
            parentSession: try PiTestSupport.makeParentSession(model: "glm-5.1", provider: "zai", thinking: "low")
        )

        XCTAssertNil(selection.provider)
        XCTAssertEqual(selection.modelArgument, "openai-codex/gpt-5.5:high")
        XCTAssertEqual(selection.displayName, "openai-codex/gpt-5.5:high")
    }

    @MainActor
    func testThinkingSuffixIsNotDuplicated() throws {
        let selection = PiSubagentLaunchPlanner.modelSelection(
            for: PiTestSupport.makeAgent(model: nil, thinking: nil),
            parentSession: try PiTestSupport.makeParentSession(model: "glm-5.1:low", provider: "zai", thinking: "low")
        )

        XCTAssertEqual(selection.provider, "zai")
        XCTAssertEqual(selection.modelArgument, "glm-5.1:low")
        XCTAssertEqual(selection.displayName, "zai/glm-5.1:low")
    }

    @MainActor
    func testInheritedLaunchArgumentsIncludeProviderAndModel() throws {
        let selection = PiSubagentLaunchPlanner.modelSelection(
            for: PiTestSupport.makeAgent(model: nil, thinking: nil),
            parentSession: try PiTestSupport.makeParentSession(model: "glm-5.1", provider: "zai", thinking: "low")
        )

        let arguments = PiRPCClient.launchArguments(
            provider: selection.provider,
            modelArgument: selection.modelArgument,
            extraArguments: ["--session-dir", "/tmp/agent-deck-test-session"]
        )

        XCTAssertEqual(arguments, [
            "--mode", "rpc",
            "--session-dir", "/tmp/agent-deck-test-session",
            "--provider", "zai",
            "--model", "glm-5.1:low"
        ])
    }


}

@MainActor
final class PiSubagentRunServiceSmokeTests: XCTestCase {
    func testRunSingleInjectsProjectEnvIntoChildPiProcess() throws {
        let harness = try PiTestSupport.makeEnvCaptureHarness(keys: [
            "AGENT_DECK_ENV_CHILD_SMOKE",
            "AGENT_DECK_NATIVE_SUBAGENT",
            "AGENT_DECK_SUBAGENT_AGENT",
            "AGENT_DECK_OPENAI_FAST_CONFIG"
        ])
        defer { harness.restoreEnvironment() }

        let projectURL = try PiTestSupport.temporaryProjectURL()
        let projectEnv = projectURL.appendingPathComponent(".pi/.env")
        try FileManager.default.createDirectory(at: projectEnv.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "AGENT_DECK_ENV_CHILD_SMOKE=child-project-value\n".write(to: projectEnv, atomically: true, encoding: .utf8)

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession(projectURL: projectURL)

        let run = try runner.runSingle(
            parentSession: parent,
            agent: PiTestSupport.makeAgent(name: "explorer"),
            snapshot: .empty,
            task: "report env"
        )
        defer { runner.stop(runID: run.id, parentSessionID: parent.id) }

        XCTAssertTrue(PiTestSupport.waitUntil { FileManager.default.fileExists(atPath: harness.envLog.path) })
        let captured = PiTestSupport.capturedEnvironment(in: harness.envLog)
        XCTAssertEqual(captured["AGENT_DECK_ENV_CHILD_SMOKE"], "child-project-value")
        XCTAssertEqual(captured["AGENT_DECK_NATIVE_SUBAGENT"], "1")
        XCTAssertEqual(captured["AGENT_DECK_SUBAGENT_AGENT"], "explorer")
        XCTAssertEqual(captured["AGENT_DECK_OPENAI_FAST_CONFIG"], PiNativeSubagentBridgeExtensions.openAIFastConfigURL().path)
    }

    func testRunSingleCreatesArtifactsAndRecordsResolvedModelBeforeProcessEvents() throws {
        let fakePi = try PiTestSupport.makeFakePiExecutable()
        let oldPiPath = getenv("AGENT_DECK_PI_PATH").map { String(cString: $0) }
        setenv("AGENT_DECK_PI_PATH", fakePi.path, 1)
        defer { restorePiPath(oldPiPath) }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession(model: "glm-5.1", provider: "zai", thinking: "low")

        let run = try runner.runSingle(
            parentSession: parent,
            agent: PiTestSupport.makeAgent(model: nil, thinking: nil),
            snapshot: .empty,
            task: "report current directory"
        )
        defer { runner.stop(runID: run.id, parentSessionID: parent.id) }

        XCTAssertEqual(run.model, "zai/glm-5.1:low")
        XCTAssertEqual(run.child?.model, "zai/glm-5.1:low")
        XCTAssertTrue(run.launchCommand?.contains("--provider zai") == true)
        XCTAssertTrue(run.launchCommand?.contains("--model glm-5.1:low") == true)

        let artifactDirectory = run.artifactDirectory.asFileURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactDirectory.appendingPathComponent("input.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactDirectory.appendingPathComponent("system-prompt.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactDirectory.appendingPathComponent("output.md").path))

        let persisted = store.subagentRuns(for: parent.id).first(where: { $0.id == run.id })
        XCTAssertEqual(persisted?.model, "zai/glm-5.1:low")
    }

    func testSystemPromptPlacesAgentPromptBeforeCommonBoundary() throws {
        let fakePi = try PiTestSupport.makeFakePiExecutable()
        let oldPiPath = getenv("AGENT_DECK_PI_PATH").map { String(cString: $0) }
        setenv("AGENT_DECK_PI_PATH", fakePi.path, 1)
        defer { restorePiPath(oldPiPath) }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession()

        let run = try runner.runSingle(
            parentSession: parent,
            agent: PiTestSupport.makeAgent(systemPrompt: "You are `example`, a focused test agent."),
            snapshot: .empty,
            task: "Check prompt order."
        )
        defer { runner.stop(runID: run.id, parentSessionID: parent.id) }

        let prompt = try String(contentsOf: run.artifactDirectory.asFileURL.appendingPathComponent("system-prompt.md"), encoding: .utf8)
        let agentRange = try XCTUnwrap(prompt.range(of: "You are `example`, a focused test agent."))
        let commonRange = try XCTUnwrap(prompt.range(of: "This is a delegated child session."))
        XCTAssertLessThan(agentRange.lowerBound, commonRange.lowerBound)
    }

    func testNativeSubagentsAllowProjectContextDiscovery() throws {
        let fakePi = try PiTestSupport.makeFakePiExecutable()
        let oldPiPath = getenv("AGENT_DECK_PI_PATH").map { String(cString: $0) }
        setenv("AGENT_DECK_PI_PATH", fakePi.path, 1)
        defer { restorePiPath(oldPiPath) }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession()

        let run = try runner.runSingle(
            parentSession: parent,
            agent: PiTestSupport.makeAgent(),
            snapshot: .empty,
            task: "Check context flags."
        )
        defer { runner.stop(runID: run.id, parentSessionID: parent.id) }

        let command = try XCTUnwrap(run.launchCommand)
        XCTAssertFalse(command.contains("--no-context-files"))
    }

    func testContinuationResumesChildSessionAndUpdatesSameParentCard() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-deck-continuation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("pi")
        let argsLog = directory.appendingPathComponent("args.log")
        let childSessionFile = directory.appendingPathComponent("child-session.jsonl")
        try "{}\n".write(to: childSessionFile, atomically: true, encoding: .utf8)
        let script = """
        #!/bin/sh
        printf '%s\n' '--- invocation ---' >> \(PiTestSupport.shellSingleQuoted(argsLog.path))
        printf '%s\n' "$@" >> \(PiTestSupport.shellSingleQuoted(argsLog.path))
        while IFS= read -r line; do
          case "$line" in
            *'"type":"get_state"'*)
              printf '%s\n' '{"type":"response","command":"get_state","success":true,"data":{"sessionFile":"\(childSessionFile.path)","isStreaming":false}}'
              ;;
            *'"type":"prompt"'*)
              printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}'
              printf '%s\n' '{"type":"agent_end"}'
              ;;
          esac
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let oldPiPath = getenv("AGENT_DECK_PI_PATH").map { String(cString: $0) }
        setenv("AGENT_DECK_PI_PATH", executable.path, 1)
        defer { restorePiPath(oldPiPath) }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession()

        let first = try runner.runSingle(parentSession: parent, agent: PiTestSupport.makeAgent(), snapshot: .empty, task: "First pass.")
        XCTAssertTrue(PiTestSupport.waitUntil { store.subagentRuns(for: parent.id).first(where: { $0.id == first.id })?.status == .completed })

        let continued = try runner.runSingle(parentSession: parent, agent: PiTestSupport.makeAgent(), snapshot: .empty, task: "Direct follow-up.", continueRunID: first.id)
        XCTAssertEqual(continued.id, first.id)
        XCTAssertTrue(PiTestSupport.waitUntil { store.subagentRuns(for: parent.id).first(where: { $0.id == first.id })?.child?.index == 1 && store.subagentRuns(for: parent.id).first(where: { $0.id == first.id })?.status == .completed })

        let args = try String(contentsOf: argsLog, encoding: .utf8)
        XCTAssertTrue(args.contains("--session\n\(childSessionFile.path)"))
        XCTAssertFalse(args.contains("--fork"))
        XCTAssertFalse(args.contains("--no-context-files"))

        let cards = store.transcript(for: parent.id).filter { entry in
            guard let rawJSON = entry.rawJSON,
                  let data = rawJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let runID = object["runID"] as? String else { return false }
            return UUID(uuidString: runID) == first.id
        }
        XCTAssertEqual(cards.count, 1)
        XCTAssertTrue(cards.first?.text.contains("Direct follow-up.") == true)
    }

    func testReadFirstPathsRejectAbsoluteAndParentTraversalInputs() throws {
        let fakePi = try PiTestSupport.makeFakePiExecutable()
        let oldPiPath = getenv("AGENT_DECK_PI_PATH").map { String(cString: $0) }
        setenv("AGENT_DECK_PI_PATH", fakePi.path, 1)
        defer { restorePiPath(oldPiPath) }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession()

        let run = try runner.runSingle(
            parentSession: parent,
            agent: PiTestSupport.makeAgent(defaultReads: ["README.md", "/etc/passwd", "../secret.txt"]),
            snapshot: .empty,
            task: "Read allowed files only.",
            readFirstPaths: ["agent-deck/AppViewModel.swift", "/tmp/nope", "../../outside"]
        )
        defer { runner.stop(runID: run.id, parentSessionID: parent.id) }

        XCTAssertEqual(run.readFirstPaths, ["README.md", "agent-deck/AppViewModel.swift"])
        let input = try String(contentsOf: run.artifactDirectory.asFileURL.appendingPathComponent("input.md"), encoding: .utf8)
        XCTAssertTrue(input.contains("README.md"))
        XCTAssertTrue(input.contains("agent-deck/AppViewModel.swift"))
        XCTAssertFalse(input.contains("/etc/passwd"))
        XCTAssertFalse(input.contains("../secret.txt"))
    }


    func testLaunchCommandIsolatesChildPiFromAmbientExtensionsContextAndSkills() throws {
        let customExtension = "/tmp/agent-deck-custom-extension.ts"
        let harness = try PiTestSupport.makeBridgeHarness(events: [])
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession()

        let run = try runner.runSingle(
            parentSession: parent,
            agent: PiTestSupport.makeAgent(
                tools: ["shell", "contact_supervisor"],
                extensions: [customExtension]
            ),
            snapshot: .empty,
            task: "Check isolation flags."
        )
        defer { runner.stop(runID: run.id, parentSessionID: parent.id) }

        let command = try XCTUnwrap(run.launchCommand)
        XCTAssertFalse(command.contains("--no-context-files"))
        XCTAssertTrue(command.contains("--system-prompt"))
        XCTAssertTrue(command.contains("--append-system-prompt ''"))
        XCTAssertTrue(command.contains("--no-skills"))
        XCTAssertTrue(command.contains("--no-prompt-templates"))
        XCTAssertFalse(command.contains("--prompt-template"))
        XCTAssertTrue(command.contains("--no-themes"))
        XCTAssertTrue(command.contains("--no-extensions"))
        XCTAssertTrue(command.contains("--extension"))
        XCTAssertTrue(command.contains("contact-supervisor-bridge.ts"))
        XCTAssertTrue(command.contains("agent-deck-web-access.ts"))
        XCTAssertTrue(command.contains("agent-deck-openai-fast.ts"))
        XCTAssertTrue(command.contains("system-prompt-audit-bridge.ts"))
        XCTAssertTrue(command.contains(customExtension))
        XCTAssertTrue(command.contains("--tools shell,contact_supervisor"))
        XCTAssertEqual(run.tools, ["shell", "contact_supervisor"])
    }

    func testChildRuntimeSystemPromptAuditWritesFinalPromptArtifact() throws {
        let payload = #"{"scope":"child","runID":"placeholder","agent":"explorer","systemPrompt":"Final child prompt from Pi."}"#
        let harness = try PiTestSupport.makeBridgeHarness(event: PiRPCBridgeFixtures.bridgeEditor(id: "audit-child-1", name: "system_prompt_audit", payload: payload))
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession()

        let run = try runner.runSingle(
            parentSession: parent,
            agent: PiTestSupport.makeAgent(),
            snapshot: .empty,
            task: "Capture prompt."
        )
        defer { runner.stop(runID: run.id, parentSessionID: parent.id) }

        let finalPromptURL = run.artifactDirectory.asFileURL.appendingPathComponent("final-system-prompt.md")
        XCTAssertTrue(PiTestSupport.waitUntil {
            (try? String(contentsOf: finalPromptURL, encoding: .utf8)) == "Final child prompt from Pi."
                && responseValue(id: "audit-child-1", in: harness.stdinLog) == "System prompt captured."
        })
        XCTAssertTrue(store.subagentTranscript(for: run.id).contains { $0.title == "System Prompt Captured" })
    }

    func testExplicitPrivateSkillsArePassedThroughNativePiSkillFlagWhileAmbientPiSkillsStayDisabled() throws {
        let harness = try PiTestSupport.makeBridgeHarness(events: [])
        defer { harness.restoreEnvironment() }

        let skillURL = FileManager.default.temporaryDirectory.appendingPathComponent("agent-deck-test-skill-\(UUID().uuidString).md")
        try "# Skill\nUse this private skill.".write(to: skillURL, atomically: true, encoding: .utf8)
        let skill = SkillRecord(
            id: "library:private-skill",
            name: "private-skill",
            description: nil,
            source: ScopeID(kind: .library, path: skillURL.path),
            filePath: skillURL.path,
            body: "fallback"
        )
        let snapshot = ScanSnapshot(
            projectRoot: nil,
            builtinAgents: [],
            globalAgents: [],
            projectAgents: [],
            legacyProjectAgents: [],
            effectiveAgents: [],
            libraryAgents: [],
            skills: [],
            librarySkills: [skill],
            promptTemplates: [],
            libraryPromptTemplates: [],
            settings: [],
            envKeys: [],
            warnings: []
        )
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession()

        let run = try runner.runSingle(
            parentSession: parent,
            agent: PiTestSupport.makeAgent(skills: ["private-skill"]),
            snapshot: snapshot,
            task: "Use the private skill."
        )
        defer { runner.stop(runID: run.id, parentSessionID: parent.id) }

        let authoredPrompt = try String(contentsOf: run.artifactDirectory.asFileURL.appendingPathComponent("system-prompt.md"), encoding: .utf8)
        XCTAssertFalse(authoredPrompt.contains(#"<skill name="private-skill""#))
        XCTAssertFalse(authoredPrompt.contains("# Skill\nUse this private skill."))
        let command = try XCTUnwrap(run.launchCommand)
        XCTAssertTrue(command.contains("--no-skills"))
        XCTAssertTrue(command.contains("--skill \(skillURL.path)"))
        XCTAssertTrue(command.contains("--no-prompt-templates"))
        XCTAssertFalse(command.contains("--prompt-template"))
        XCTAssertTrue(command.contains("--no-themes"))
    }

    func testMissingExplicitSkillsBlockLaunch() throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession()

        XCTAssertThrowsError(try runner.runSingle(
            parentSession: parent,
            agent: PiTestSupport.makeAgent(skills: ["missing-private-skill"]),
            snapshot: .empty,
            task: "Use missing skill if needed."
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("missing-private-skill"))
        }
    }

    func testExpectedOutcomePromptContractsAreSentToChildPi() throws {
        let reportOnly = try promptSentForOutcome(.reportOnly)
        XCTAssertTrue(reportOnly.contains("Expected outcome: Report only"))
        XCTAssertTrue(reportOnly.contains("Do not create, edit, delete, or overwrite project files."))

        let worktree = try promptSentForOutcome(.editFilesInWorktree)
        XCTAssertTrue(worktree.contains("Expected outcome: Edit files in worktree"))
        XCTAssertTrue(worktree.contains("Edit project files only in the current isolated worktree."))
        XCTAssertTrue(worktree.contains("\(AppBrand.displayName) will review/apply/discard the worktree diff."))

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
            task: "Report progress."
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
            task: "Ask for decision."
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
            task: "Ask to interview the user."
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
            expectedOutcome: expectedOutcome,
            requestedOutputPath: requestedOutputPath,
            allowOverwrite: false
        )
        defer { runner.stop(runID: run.id, parentSessionID: parent.id) }

        XCTAssertTrue(PiTestSupport.waitUntil {
            guard let log = try? String(contentsOf: harness.stdinLog, encoding: .utf8) else { return false }
            return log.contains("Expected outcome")
        })
        let log = try String(contentsOf: harness.stdinLog, encoding: .utf8)
        let prompts = log
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["type"] as? String == "prompt" else {
                    return nil
                }
                return object["message"] as? String
            }
        return try XCTUnwrap(prompts.first { $0.contains("Expected outcome") })
    }

    private func restorePiPath(_ oldPiPath: String?) {
        if let oldPiPath {
            setenv("AGENT_DECK_PI_PATH", oldPiPath, 1)
        } else {
            unsetenv("AGENT_DECK_PI_PATH")
        }
    }
}

private extension String {
    var asFileURL: URL {
        URL(fileURLWithPath: self)
    }
}
