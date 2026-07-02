import XCTest
@testable import agent_deck

final class PiAgentContextEstimateBuilderTests: XCTestCase {
    @MainActor
    func testEstimatedRowsUseRpcTokenTotalsAndFreeSpace() {
        let session = makeSession(
            inputTokens: 800,
            outputTokens: 50,
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

        XCTAssertEqual(estimate.rows.first(where: { $0.key == "estimatedInputTokens" })?.tokens, 800)
        XCTAssertEqual(estimate.rows.first(where: { $0.key == "estimatedOutputTokens" })?.tokens, 50)
        XCTAssertEqual(estimate.rows.first(where: { $0.key == "estimatedCacheTokens" })?.tokens, 150)
        XCTAssertNil(estimate.rows.first(where: { $0.key == "estimatedMessages" }))
        XCTAssertEqual(estimate.rows.first(where: { $0.key == "estimatedFreeSpace" })?.tokens, 1_000)
        XCTAssertTrue(estimate.note.contains("Estimated"))
    }

    @MainActor
    func testEstimatedRowsDoNotReserveModelMaxOutputFromFreeSpace() {
        let session = makeSession(
            model: "gpt-test",
            modelProvider: "openai",
            contextTokens: 1_000,
            contextWindow: 2_000,
            contextPercent: 50
        )

        let estimate = PiAgentContextEstimateBuilder.build(session: session, transcript: [])

        XCTAssertNil(estimate.rows.first(where: { $0.key == "estimatedOutputBuffer" }))
        XCTAssertEqual(estimate.rows.first(where: { $0.key == "estimatedFreeSpace" })?.tokens, 1_000)
    }

    @MainActor
    func testBuildsPromptCompositionFromCapturedSystemPrompt() {
        let prompt = """
        Core guidance.

        Available tools:
        read: read files
        bash: run commands

        # Project Context
        AGENTS.md guidance.

        <available_skills>
        <skill><name>review</name><description>Review code.</description><location>/tmp/review/SKILL.md</location></skill>
        </available_skills>
        """

        let composition = PiAgentContextEstimateBuilder.buildPromptComposition(systemPrompt: prompt)

        XCTAssertNotNil(composition)
        XCTAssertEqual(composition?.rows.first(where: { $0.key == "promptTools" })?.title, "Tool descriptions")
        XCTAssertNotNil(composition?.rows.first(where: { $0.key == "promptProjectContext" }))
        XCTAssertNotNil(composition?.rows.first(where: { $0.key == "promptSkills" }))
        XCTAssertNotNil(composition?.rows.first(where: { $0.key == "promptCore" }))
        XCTAssertGreaterThan(composition?.totalTokens ?? 0, 0)
    }

    @MainActor
    func testParsesCompactTokenCounts() {
        XCTAssertEqual(PiAgentContextEstimateBuilder.parseTokenCount("128k"), 128_000)
        XCTAssertEqual(PiAgentContextEstimateBuilder.parseTokenCount("1.5m"), 1_500_000)
        XCTAssertEqual(PiAgentContextEstimateBuilder.parseTokenCount("16,384"), 16_384)
    }

    @MainActor
    private func makeSession(
        model: String? = nil,
        modelProvider: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
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
            projectPath: "/tmp/agent-deck-test-project",
            projectName: "agent-deck-test-project",
            repository: nil,
            issueNumber: nil,
            issueURL: nil,
            piSessionFile: nil,
            piSessionId: nil,
            model: model,
            modelProvider: modelProvider,
            modelOverrideID: nil,
            modelOverrideProvider: nil,
            thinkingLevel: nil,
            launchCommand: nil,
            branchName: nil,
            worktreePath: nil,
            status: .idle,
            lastError: nil,
            lastSummary: nil,
            needsAttention: false,
            lastNotificationAt: nil,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            totalTokens: nil,
            toolCalls: nil,
            toolResults: nil,
            contextTokens: contextTokens,
            contextWindow: contextWindow,
            contextPercent: contextPercent,
            cost: nil,
            finalSystemPrompt: nil,
            finalSystemPromptCapturedAt: nil,
            pendingSteeringMessages: [],
            pendingFollowUpMessages: [],
            subagentsEnabled: true,
            injectedExtensions: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

final class PiModelDiscoveryServiceTests: XCTestCase {
    @MainActor
    func testParsesPiModelListRows() {
        let output = """
provider model context output thinking images
openai gpt-5.2 400k 128k yes yes
anthropic claude-sonnet-4.5 200k 64k no no
"""

        let models = PiModelDiscoveryService.parseAvailableModels(
            from: output,
            exactThinkingLevels: ["openai/gpt-5.2": ["off", "low", "medium", "high"]]
        )

        XCTAssertEqual(models.map(\.identifier), ["openai/gpt-5.2", "anthropic/claude-sonnet-4.5"])
        XCTAssertEqual(models.first?.supportedThinkingLevels, ["off", "low", "medium", "high"])
        XCTAssertEqual(models.last?.supportedThinkingLevels, ["off"])
    }

    @MainActor
    func testExtractsProviderAndModelIdentifiers() {
        let output = """
provider model context output thinking images
openai gpt-5.2 400k 128k yes yes
"""

        let identifiers = PiModelDiscoveryService.availableModelIdentifiers(fromPiListOutput: output)

        XCTAssertEqual(identifiers.first?.provider, "openai")
        XCTAssertEqual(identifiers.first?.model, "gpt-5.2")
    }

    @MainActor
    func testVertexProviderThinkingLevelsUseTargetedAliasFallback() async {
        let output = """
provider model context output thinking images
google-vertex gemini-2.5-pro 1M 64K yes yes
"""
        let runner = FakeModelDiscoveryCommandRunner(
            listOutput: output,
            nodeOutput: #"{"google-vertex/gemini-2.5-pro":["off","low","medium","high"]}"#
        )
        let service = PiModelDiscoveryService(
            commandRunner: runner,
            piResolver: PiExecutableResolver(candidatesProvider: { [] }, defaultPathDirectories: { [] })
        )

        let models = await service.loadAvailableModels()
        let script = await runner.nodeScript ?? ""

        XCTAssertTrue(script.contains("item.provider.endsWith('-vertex')"))
        XCTAssertTrue(script.contains("byKey.get(`${baseProvider}/${item.model}`)"))
        XCTAssertEqual(models.first?.identifier, "google-vertex/gemini-2.5-pro")
        XCTAssertEqual(models.first?.supportedThinkingLevels, ["off", "low", "medium", "high"])
    }
}

final class PiProviderCatalogServiceTests: XCTestCase {
    @MainActor
    func testConnectableProvidersMergeFallbacksWhenLoadedListIsPartial() async {
        let runner = FakeModelDiscoveryCommandRunner(
            listOutput: "",
            nodeOutput: #"["neuralwatt"]"#
        )
        let service = PiProviderCatalogService(
            commandRunner: runner,
            piResolver: PiExecutableResolver(candidatesProvider: { [] }, defaultPathDirectories: { [] })
        )

        let providers = await service.loadConnectableProviders()

        XCTAssertTrue(providers.contains("neuralwatt"))
        XCTAssertTrue(providers.contains("openrouter"))
        XCTAssertTrue(providers.contains("anthropic"))
        XCTAssertTrue(providers.contains("zai"))
        XCTAssertTrue(providers.contains("opencode-go"))
        XCTAssertEqual(providers.filter { $0 == "neuralwatt" }.count, 1)
    }
}

private actor FakeModelDiscoveryCommandRunner: CommandRunning {
    private let listOutput: String
    private let nodeOutput: String
    private(set) var nodeScript: String?

    init(listOutput: String, nodeOutput: String) {
        self.listOutput = listOutput
        self.nodeOutput = nodeOutput
    }

    func run(
        _ command: String,
        arguments: [String],
        currentDirectoryURL: URL?,
        timeout: TimeInterval?,
        environment: [String: String]?
    ) async throws -> CommandResult {
        if arguments == ["--list-models"] {
            return CommandResult(stdout: listOutput, stderr: "", exitCode: 0)
        }
        if command == "node" {
            nodeScript = arguments.last
            return CommandResult(stdout: nodeOutput, stderr: "", exitCode: 0)
        }
        return CommandResult(stdout: "", stderr: "unexpected command", exitCode: 1)
    }
}
