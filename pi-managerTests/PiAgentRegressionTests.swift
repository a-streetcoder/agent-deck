import XCTest
@testable import pi_manager

@MainActor
final class PiAgentSessionStoreRegressionTests: XCTestCase {
    func testSessionPlanSetAndUpdateAreStableInPlace() {
        let store = makeStore()
        let session = store.createSession(kind: .project, title: "Smoke", project: makeProject(), repository: nil)

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

    func testCreatedSessionSelectionPersistsAcrossReload() {
        let fileURL = temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        let session = firstStore.createSession(kind: .project, title: "Selected", project: makeProject(), repository: nil)
        firstStore.flushForTesting()

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)

        XCTAssertEqual(reloadedStore.selectedSessionID, session.id)
        XCTAssertEqual(reloadedStore.selectedSession?.id, session.id)
    }

    func testReloadWithNilPersistedSelectionSelectsFirstSession() throws {
        let fileURL = temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        let session = firstStore.createSession(kind: .project, title: "Selected", project: makeProject(), repository: nil)
        firstStore.flushForTesting()
        try rewritePersistedSelection(in: fileURL, selectedSessionID: NSNull())

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)

        XCTAssertEqual(reloadedStore.selectedSessionID, session.id)
        XCTAssertEqual(reloadedStore.selectedSession?.id, session.id)
    }

    func testReloadWithInvalidPersistedSelectionSelectsFirstSession() throws {
        let fileURL = temporaryStateFile()
        let firstStore = PiAgentSessionStore(fileURL: fileURL)
        let session = firstStore.createSession(kind: .project, title: "Selected", project: makeProject(), repository: nil)
        firstStore.flushForTesting()
        try rewritePersistedSelection(in: fileURL, selectedSessionID: UUID().uuidString)

        let reloadedStore = PiAgentSessionStore(fileURL: fileURL)

        XCTAssertEqual(reloadedStore.selectedSessionID, session.id)
        XCTAssertEqual(reloadedStore.selectedSession?.id, session.id)
    }

    private func makeStore() -> PiAgentSessionStore {
        PiAgentSessionStore(fileURL: temporaryStateFile())
    }

    private func temporaryStateFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-manager-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("agent-sessions.json")
    }

    private func makeProject() -> DiscoveredProject {
        DiscoveredProject(
            url: URL(fileURLWithPath: "/tmp/pi-manager-test-project"),
            gitHubRemote: nil,
            isGitRepository: true,
            iconFileURL: nil,
            fallbackSymbolName: "folder",
            searchIndex: "pi-manager-test-project"
        )
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

final class PiSubagentLaunchPlannerRegressionTests: XCTestCase {
    func testDefaultAgentInheritsParentProviderModelAndThinking() {
        let selection = PiSubagentLaunchPlanner.modelSelection(
            for: makeAgent(model: nil, thinking: nil),
            parentSession: makeParentSession(model: "glm-5.1", provider: "zai", thinking: "low")
        )

        XCTAssertEqual(selection.provider, "zai")
        XCTAssertEqual(selection.modelArgument, "glm-5.1:low")
        XCTAssertEqual(selection.displayName, "zai/glm-5.1:low")
    }

    func testExplicitAgentModelWinsOverParentModel() {
        let selection = PiSubagentLaunchPlanner.modelSelection(
            for: makeAgent(model: "openai-codex/gpt-5.5", thinking: "high"),
            parentSession: makeParentSession(model: "glm-5.1", provider: "zai", thinking: "low")
        )

        XCTAssertNil(selection.provider)
        XCTAssertEqual(selection.modelArgument, "openai-codex/gpt-5.5:high")
        XCTAssertEqual(selection.displayName, "openai-codex/gpt-5.5:high")
    }

    func testThinkingSuffixIsNotDuplicated() {
        let selection = PiSubagentLaunchPlanner.modelSelection(
            for: makeAgent(model: nil, thinking: nil),
            parentSession: makeParentSession(model: "glm-5.1:low", provider: "zai", thinking: "low")
        )

        XCTAssertEqual(selection.provider, "zai")
        XCTAssertEqual(selection.modelArgument, "glm-5.1:low")
        XCTAssertEqual(selection.displayName, "zai/glm-5.1:low")
    }

    func testInheritedLaunchArgumentsIncludeProviderAndModel() {
        let selection = PiSubagentLaunchPlanner.modelSelection(
            for: makeAgent(model: nil, thinking: nil),
            parentSession: makeParentSession(model: "glm-5.1", provider: "zai", thinking: "low")
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

    func testPreStateRunMetadataUsesResolvedProviderModelDisplayName() throws {
        let fakePi = try makeFakePiExecutable()
        let oldPiPath = getenv("PI_MANAGER_PI_PATH").map { String(cString: $0) }
        setenv("PI_MANAGER_PI_PATH", fakePi.path, 1)
        defer {
            if let oldPiPath {
                setenv("PI_MANAGER_PI_PATH", oldPiPath, 1)
            } else {
                unsetenv("PI_MANAGER_PI_PATH")
            }
        }

        let store = PiAgentSessionStore(fileURL: temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = makeParentSession(model: "glm-5.1", provider: "zai", thinking: "low")
        try FileManager.default.createDirectory(atPath: parent.projectPath, withIntermediateDirectories: true)

        let run = try runner.runSingle(
            parentSession: parent,
            agent: makeAgent(model: nil, thinking: nil),
            snapshot: .empty,
            task: "report current directory",
            requestedContext: .fresh
        )
        defer { runner.stop(runID: run.id, parentSessionID: parent.id) }

        XCTAssertEqual(run.model, "zai/glm-5.1:low")
        XCTAssertEqual(run.child?.model, "zai/glm-5.1:low")
        XCTAssertTrue(run.launchCommand?.contains("--provider zai") == true)
        XCTAssertTrue(run.launchCommand?.contains("--model glm-5.1:low") == true)

        let persisted = store.subagentRuns(for: parent.id).first(where: { $0.id == run.id })
        XCTAssertEqual(persisted?.model, "zai/glm-5.1:low")
        XCTAssertEqual(persisted?.child?.model, "zai/glm-5.1:low")
    }

    func testForkContextRequiresParentSessionFile() {
        let agent = makeAgent(model: nil, thinking: nil, defaultContext: "fork")

        XCTAssertEqual(
            PiSubagentLaunchPlanner.resolvedContextMode(for: agent, parentSession: makeParentSession(piSessionFile: nil), requestedContext: .fork),
            .fresh
        )
        XCTAssertEqual(
            PiSubagentLaunchPlanner.resolvedContextMode(for: agent, parentSession: makeParentSession(piSessionFile: "/tmp/parent.jsonl"), requestedContext: .agentDefault),
            .fork
        )
    }

    func testForkedRunUsesSanitizedReferenceSessionInArtifactDirectory() throws {
        let fakePi = try makeFakePiExecutable()
        let oldPiPath = getenv("PI_MANAGER_PI_PATH").map { String(cString: $0) }
        setenv("PI_MANAGER_PI_PATH", fakePi.path, 1)
        defer {
            if let oldPiPath {
                setenv("PI_MANAGER_PI_PATH", oldPiPath, 1)
            } else {
                unsetenv("PI_MANAGER_PI_PATH")
            }
        }

        let parentSessionFile = try makeParentSessionFileWithActiveManagedSubagentCall()
        let store = PiAgentSessionStore(fileURL: temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = makeParentSession(piSessionFile: parentSessionFile.path)
        try FileManager.default.createDirectory(atPath: parent.projectPath, withIntermediateDirectories: true)

        let run = try runner.runSingle(
            parentSession: parent,
            agent: makeAgent(model: nil, thinking: nil),
            snapshot: .empty,
            task: "Say whether you were launched with forked context. Then answer fork context smoke completed.",
            requestedContext: .fork
        )
        defer { runner.stop(runID: run.id, parentSessionID: parent.id) }

        let artifactPath = try XCTUnwrap(run.artifactDirectory)
        let artifactDirectory = URL(fileURLWithPath: artifactPath)
        let forkContextURL = artifactDirectory.appendingPathComponent("fork-context.jsonl")
        let forkContext = try String(contentsOf: forkContextURL, encoding: .utf8)

        XCTAssertEqual(run.resolvedContext, .fork)
        XCTAssertTrue(run.launchCommand?.contains("--fork") == true)
        XCTAssertTrue(run.launchCommand?.contains("fork-context.jsonl") == true)
        XCTAssertTrue(run.launchCommand?.contains("--session-dir") == true)
        XCTAssertTrue(run.launchCommand?.contains("/sessions") == true)
        XCTAssertFalse(run.launchCommand?.contains(parentSessionFile.path) == true)
        XCTAssertTrue(forkContext.contains("Earlier useful context"))
        XCTAssertTrue(forkContext.contains("Pi Manager native subagent boundary"))
        XCTAssertFalse(forkContext.contains("Use managed_subagent with agent scout"))
        XCTAssertFalse(forkContext.contains("\"name\":\"managed_subagent\""))
    }

    private func makeAgent(model: String?, thinking: String?, defaultContext: String? = nil) -> EffectiveAgentRecord {
        var config = AgentConfig.empty
        config.name = "scout"
        config.description = "Scout"
        config.model = model
        config.thinking = thinking
        config.defaultContext = defaultContext
        return EffectiveAgentRecord(
            id: "scout",
            name: "scout",
            projectRoot: "/tmp/pi-manager-test-project",
            builtin: nil,
            globalCustom: nil,
            projectCustom: nil,
            userOverride: nil,
            projectOverride: nil,
            resolved: config,
            resolutionKind: .builtin
        )
    }

    private func makeParentSessionFileWithActiveManagedSubagentCall() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-manager-parent-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("parent.jsonl")
        let lines = [
            #"{"type":"session","version":3,"id":"019dfa20-a8c3-7659-829e-078c2e704c1b","timestamp":"2026-05-05T21:52:17.603Z","cwd":"/tmp/pi-manager-test-project"}"#,
            #"{"type":"message","id":"old-user","parentId":null,"timestamp":"2026-05-05T21:53:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Earlier useful context"}]}}"#,
            #"{"type":"message","id":"old-assistant","parentId":"old-user","timestamp":"2026-05-05T21:53:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Earlier assistant answer"}],"provider":"zai","model":"glm-5.1"}}"#,
            #"{"type":"message","id":"active-user","parentId":"old-assistant","timestamp":"2026-05-05T23:50:42.964Z","message":{"role":"user","content":[{"type":"text","text":"Use managed_subagent with agent scout, context fork, and task:\nSay whether you were launched with forked context."}]}}"#,
            #"{"type":"message","id":"active-assistant","parentId":"active-user","timestamp":"2026-05-05T23:50:47.657Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_active","name":"managed_subagent","arguments":{"agent":"scout","context":"fork","task":"Say whether you were launched with forked context."}}],"provider":"zai","model":"glm-5.1","stopReason":"toolUse"}}"#
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func makeParentSession(model: String? = nil, provider: String? = nil, thinking: String? = nil, piSessionFile: String? = nil) -> PiAgentSessionRecord {
        PiAgentSessionRecord(
            id: UUID(),
            kind: .project,
            title: "Parent",
            projectPath: "/tmp/pi-manager-test-project",
            projectName: "pi-manager-test-project",
            repository: nil,
            issueNumber: nil,
            issueURL: nil,
            piSessionFile: piSessionFile,
            piSessionId: nil,
            model: model,
            modelProvider: provider,
            modelOverrideID: nil,
            modelOverrideProvider: nil,
            availableModels: nil,
            thinkingLevel: thinking,
            launchCommand: nil,
            branchName: nil,
            worktreePath: nil,
            status: .draft,
            lastError: nil,
            lastSummary: nil,
            needsAttention: false,
            lastNotificationAt: nil,
            inputTokens: nil,
            outputTokens: nil,
            cacheReadTokens: nil,
            cacheWriteTokens: nil,
            totalTokens: nil,
            toolCalls: nil,
            toolResults: nil,
            contextTokens: nil,
            contextWindow: nil,
            contextPercent: nil,
            cost: nil,
            pendingSteeringMessages: [],
            pendingFollowUpMessages: [],
            subagentsEnabled: true,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private func makeFakePiExecutable() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-manager-fake-pi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("pi")
        let script = """
        #!/bin/sh
        while IFS= read -r line; do
          sleep 1
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func temporaryStateFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-manager-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("agent-sessions.json")
    }
}
