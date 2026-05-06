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
}

final class PiSubagentLaunchPlannerRegressionTests: XCTestCase {
    func testDefaultAgentInheritsParentProviderModelAndThinking() {
        let selection = PiSubagentLaunchPlanner.modelSelection(
            for: makeAgent(model: nil, thinking: nil),
            parentSession: makeParentSession(model: "glm-5.1", provider: "zai", thinking: "low")
        )

        XCTAssertEqual(selection.provider, "zai")
        XCTAssertEqual(selection.modelArgument, "glm-5.1:low")
    }

    func testExplicitAgentModelWinsOverParentModel() {
        let selection = PiSubagentLaunchPlanner.modelSelection(
            for: makeAgent(model: "openai-codex/gpt-5.5", thinking: "high"),
            parentSession: makeParentSession(model: "glm-5.1", provider: "zai", thinking: "low")
        )

        XCTAssertNil(selection.provider)
        XCTAssertEqual(selection.modelArgument, "openai-codex/gpt-5.5:high")
    }

    func testThinkingSuffixIsNotDuplicated() {
        let selection = PiSubagentLaunchPlanner.modelSelection(
            for: makeAgent(model: nil, thinking: nil),
            parentSession: makeParentSession(model: "glm-5.1:low", provider: "zai", thinking: "low")
        )

        XCTAssertEqual(selection.provider, "zai")
        XCTAssertEqual(selection.modelArgument, "glm-5.1:low")
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
}
