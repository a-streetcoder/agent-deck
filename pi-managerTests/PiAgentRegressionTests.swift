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

final class PiAgentContextEstimateBuilderTests: XCTestCase {
    func testEstimatedRowsUseTranscriptCacheAndRpcFreeSpace() {
        let session = makeSession(
            cacheReadTokens: 100,
            cacheWriteTokens: 50,
            contextTokens: 1_000,
            contextWindow: 2_000,
            contextPercent: 50
        )
        let transcript = [
            PiAgentTranscriptEntry(sessionID: session.id, role: .user, title: "User", text: String(repeating: "a", count: 4_000)),
            PiAgentTranscriptEntry(sessionID: session.id, role: .status, title: "Status", text: String(repeating: "b", count: 4_000))
        ]

        let estimate = PiAgentContextEstimateBuilder.build(session: session, transcript: transcript)

        XCTAssertEqual(estimate.rows.first(where: { $0.key == "estimatedMessages" })?.tokens, 850)
        XCTAssertEqual(estimate.rows.first(where: { $0.key == "estimatedCachedPromptTools" })?.tokens, 150)
        XCTAssertEqual(estimate.rows.first(where: { $0.key == "estimatedFreeSpace" })?.tokens, 1_000)
        XCTAssertTrue(estimate.note.contains("Estimated"))
        XCTAssertTrue(estimate.note.contains("Exact category data is not exposed"))
    }

    func testEstimatedRowsReserveKnownOutputBuffer() {
        let session = makeSession(
            model: "gpt-test",
            modelProvider: "openai",
            availableModels: [
                PiAgentModelOption(
                    provider: "openai",
                    id: "gpt-test",
                    name: nil,
                    contextWindow: 2_000,
                    maxOutput: 200,
                    supportsThinking: true,
                    supportedThinkingLevels: ["off", "low"],
                    supportsImages: false
                )
            ],
            contextTokens: 1_000,
            contextWindow: 2_000,
            contextPercent: 50
        )

        let estimate = PiAgentContextEstimateBuilder.build(session: session, transcript: [])

        XCTAssertEqual(estimate.rows.first(where: { $0.key == "estimatedOutputBuffer" })?.tokens, 200)
        XCTAssertEqual(estimate.rows.first(where: { $0.key == "estimatedFreeSpace" })?.tokens, 800)
    }

    func testEstimatedRowsKeepUnattributedUsedContextVisible() {
        let session = makeSession(
            contextTokens: 1_000,
            contextWindow: 2_000,
            contextPercent: 50
        )

        let estimate = PiAgentContextEstimateBuilder.build(session: session, transcript: [])

        XCTAssertEqual(estimate.rows.first(where: { $0.key == "estimatedOtherUsedContext" })?.tokens, 1_000)
        XCTAssertEqual(estimate.rows.first(where: { $0.key == "estimatedFreeSpace" })?.tokens, 1_000)
    }

    func testParsesCompactTokenCounts() {
        XCTAssertEqual(PiAgentContextEstimateBuilder.parseTokenCount("128k"), 128_000)
        XCTAssertEqual(PiAgentContextEstimateBuilder.parseTokenCount("1.5m"), 1_500_000)
        XCTAssertEqual(PiAgentContextEstimateBuilder.parseTokenCount("16,384"), 16_384)
    }

    private func makeSession(
        model: String? = nil,
        modelProvider: String? = nil,
        availableModels: [PiAgentModelOption]? = nil,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        contextTokens: Int?,
        contextWindow: Int?,
        contextPercent: Double?
    ) -> PiAgentSessionRecord {
        PiAgentSessionRecord(
            id: UUID(),
            kind: .project,
            title: "Context",
            projectPath: "/tmp/pi-manager-test-project",
            projectName: "pi-manager-test-project",
            repository: nil,
            issueNumber: nil,
            issueURL: nil,
            piSessionFile: nil,
            piSessionId: nil,
            model: model,
            modelProvider: modelProvider,
            modelOverrideID: nil,
            modelOverrideProvider: nil,
            availableModels: availableModels,
            thinkingLevel: nil,
            launchCommand: nil,
            branchName: nil,
            worktreePath: nil,
            status: .idle,
            lastError: nil,
            lastSummary: nil,
            needsAttention: false,
            lastNotificationAt: nil,
            inputTokens: nil,
            outputTokens: nil,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            totalTokens: nil,
            toolCalls: nil,
            toolResults: nil,
            contextTokens: contextTokens,
            contextWindow: contextWindow,
            contextPercent: contextPercent,
            cost: nil,
            pendingSteeringMessages: [],
            pendingFollowUpMessages: [],
            subagentsEnabled: true,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

@MainActor
final class PiAgentRunnerBridgeRegressionTests: XCTestCase {
    func testSetSessionPlanBridgePersistsPlanAndRespondsToEditorRequest() throws {
        let payload = #"{"kind":"set_session_plan","toolCallId":"tool-1","items":[{"id":"inspect","title":"Inspect smoke","status":"in_progress"},{"id":"delegate","title":"Run native subagent smoke","status":"todo"},{"id":"finish","title":"Summarize result","status":"todo"}]}"#
        let harness = try makeBridgeHarness(event: [
            "type": "extension_ui_request",
            "id": "bridge-plan-1",
            "method": "editor",
            "title": "PI_MANAGER_BRIDGE set_session_plan",
            "prefill": payload
        ])
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        runner.onSessionPlanSet = { sessionID, request in
            let plan = store.setSessionPlan(sessionID: sessionID, items: request.items)
            return "Session plan set. \(plan.items.count) item(s)."
        }
        let session = store.createSession(kind: .project, title: "Bridge", project: try makeProject(), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(waitUntil {
            store.sessionPlan(for: session.id)?.items.count == 3
                && extensionUIResponses(in: harness.stdinLog).contains { $0["id"] as? String == "bridge-plan-1" }
        })

        let plan = try XCTUnwrap(store.sessionPlan(for: session.id))
        XCTAssertEqual(plan.items.map(\.id), ["inspect", "delegate", "finish"])
        XCTAssertEqual(plan.items.map(\.status), [.inProgress, .todo, .todo])
        XCTAssertNil(store.uiRequestsBySessionID[session.id], "Bridge editor requests must not become interactive editor cards.")

        let response = try XCTUnwrap(extensionUIResponses(in: harness.stdinLog).first { $0["id"] as? String == "bridge-plan-1" })
        XCTAssertEqual(response["type"] as? String, "extension_ui_response")
        XCTAssertEqual(response["value"] as? String, "Session plan set. 3 item(s).")
    }

    func testMalformedSessionPlanBridgeStillRespondsAndDoesNotOpenEditorUI() throws {
        let harness = try makeBridgeHarness(event: [
            "type": "extension_ui_request",
            "id": "bridge-plan-bad",
            "method": "editor",
            "title": "PI_MANAGER_BRIDGE set_session_plan",
            "prefill": "{not-json"
        ])
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        let session = store.createSession(kind: .project, title: "Bridge", project: try makeProject(), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(waitUntil {
            extensionUIResponses(in: harness.stdinLog).contains { $0["id"] as? String == "bridge-plan-bad" }
        })

        XCTAssertNil(store.sessionPlan(for: session.id))
        XCTAssertNil(store.uiRequestsBySessionID[session.id], "Malformed bridge requests should still be handled as bridge traffic.")
        let response = try XCTUnwrap(extensionUIResponses(in: harness.stdinLog).first { $0["id"] as? String == "bridge-plan-bad" })
        XCTAssertEqual(response["value"] as? String, "Pi Manager could not parse the session plan request.")
    }

    func testNestedBridgeEditorShapePersistsPlanAndResponds() throws {
        let payload = #"{"kind":"set_session_plan","items":[{"id":"inspect","title":"Inspect smoke","status":"in_progress"}]}"#
        let harness = try makeBridgeHarness(event: [
            "type": "extension_ui_request",
            "data": [
                "id": "bridge-plan-nested",
                "method": "editor",
                "title": "PI_MANAGER_BRIDGE set_session_plan",
                "prefill": payload
            ]
        ])
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        runner.onSessionPlanSet = { sessionID, request in
            let plan = store.setSessionPlan(sessionID: sessionID, items: request.items)
            return "Session plan set. \(plan.items.count) item(s)."
        }
        let session = store.createSession(kind: .project, title: "Bridge", project: try makeProject(), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(waitUntil {
            store.sessionPlan(for: session.id)?.items.count == 1
                && extensionUIResponses(in: harness.stdinLog).contains { $0["id"] as? String == "bridge-plan-nested" }
        })

        XCTAssertEqual(store.sessionPlan(for: session.id)?.items.first?.id, "inspect")
        XCTAssertNil(store.uiRequestsBySessionID[session.id])
    }

    func testRegularEditorRequestStillBecomesInteractiveUIRequest() throws {
        let harness = try makeBridgeHarness(event: [
            "type": "extension_ui_request",
            "id": "editor-1",
            "method": "editor",
            "title": "Edit response",
            "prefill": "Draft"
        ])
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        let session = store.createSession(kind: .project, title: "Bridge", project: try makeProject(), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(waitUntil {
            store.uiRequestsBySessionID[session.id]?.id == "editor-1"
        })

        let request = try XCTUnwrap(store.uiRequestsBySessionID[session.id])
        XCTAssertEqual(request.method, .editor)
        XCTAssertEqual(request.title, "Edit response")
        XCTAssertEqual(request.prefill, "Draft")
        XCTAssertTrue(extensionUIResponses(in: harness.stdinLog).isEmpty)
    }

    private struct BridgeHarness {
        let stdinLog: URL
        let restoreEnvironment: () -> Void
    }

    private func makeBridgeHarness(event: [String: Any]) throws -> BridgeHarness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-manager-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let eventFile = directory.appendingPathComponent("event.json")
        let stdinLog = directory.appendingPathComponent("stdin.log")
        let executable = directory.appendingPathComponent("pi")
        let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        try data.write(to: eventFile)

        let script = """
        #!/bin/sh
        sleep 0.2
        cat \(shellSingleQuoted(eventFile.path))
        printf '\\n'
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> \(shellSingleQuoted(stdinLog.path))
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let oldPiPath = getenv("PI_MANAGER_PI_PATH").map { String(cString: $0) }
        setenv("PI_MANAGER_PI_PATH", executable.path, 1)
        return BridgeHarness(stdinLog: stdinLog) {
            if let oldPiPath {
                setenv("PI_MANAGER_PI_PATH", oldPiPath, 1)
            } else {
                unsetenv("PI_MANAGER_PI_PATH")
            }
        }
    }

    private func extensionUIResponses(in logURL: URL) -> [[String: Any]] {
        guard let content = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return content
            .split(separator: "\n")
            .compactMap { line -> [String: Any]? in
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["type"] as? String == "extension_ui_response" else {
                    return nil
                }
                return object
            }
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func makeProject() throws -> DiscoveredProject {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pi-manager-test-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return DiscoveredProject(
            url: url,
            gitHubRemote: nil,
            isGitRepository: true,
            iconFileURL: nil,
            fallbackSymbolName: "folder",
            searchIndex: "pi-manager-test-project"
        )
    }

    private func temporaryStateFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-manager-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("agent-sessions.json")
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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
