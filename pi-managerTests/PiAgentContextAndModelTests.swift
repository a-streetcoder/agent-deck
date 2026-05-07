import XCTest
@testable import pi_manager

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

final class PiModelDiscoveryServiceTests: XCTestCase {
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

    func testExtractsProviderAndModelIdentifiers() {
        let output = """
provider model context output thinking images
openai gpt-5.2 400k 128k yes yes
"""

        let identifiers = PiModelDiscoveryService.availableModelIdentifiers(fromPiListOutput: output)

        XCTAssertEqual(identifiers.first?.provider, "openai")
        XCTAssertEqual(identifiers.first?.model, "gpt-5.2")
    }
}
