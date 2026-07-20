import XCTest
@testable import agent_deck

final class MCPAssignmentTests: XCTestCase {
    // MARK: - Agent frontmatter

    @MainActor
    func testAgentConfigSerializesMcpServersFrontmatter() {
        var config = AgentConfig.empty
        config.name = "reviewer"
        config.mcpServers = ["github", "linear"]
        let text = AgentPersistence().serializedText(for: config)
        XCTAssertTrue(text.contains("mcpServers: github, linear"), "serialized agent should carry mcpServers; got:\n\(text)")
    }

    @MainActor
    func testAgentConfigOmitsMcpServersWhenNil() {
        var config = AgentConfig.empty
        config.name = "reviewer"
        config.mcpServers = nil
        XCTAssertFalse(AgentPersistence().serializedText(for: config).contains("mcpServers:"))
    }

    // MARK: - Project preference

    @MainActor
    func testProjectPreferenceRoundTripsAssignedMcpServers() throws {
        let preference = ProjectPreference(
            path: "/tmp/project",
            isEnabled: true,
            isHidden: false,
            customIconPath: nil,
            assignedMcpServerNames: ["github", "filesystem"]
        )
        let data = try JSONEncoder().encode(preference)
        let decoded = try JSONDecoder().decode(ProjectPreference.self, from: data)
        XCTAssertEqual(decoded.assignedMcpServerNames, ["github", "filesystem"])
    }

    @MainActor
    func testProjectPreferenceDefaultsToEmptyMcpAssignment() {
        XCTAssertTrue(ProjectPreference.default(for: "/tmp/x").assignedMcpServerNames.isEmpty)
    }

    /// Regression: the store's reload reconstruction once dropped
    /// `assignedMcpServerNames` (the Codable round-trip was fine, but
    /// `loadPreferences` rebuilt the struct and forgot the field), so assignments
    /// vanished on relaunch. This exercises that exact reconstruction path.
    @MainActor
    func testStoreReloadPreservesAssignedMcpServers() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "mcp.assignment.reload.test"))
        defer { suite.removePersistentDomain(forName: "mcp.assignment.reload.test") }
        let key = "projectPreferences.test"

        let collectionID = UUID()
        let saved = [ProjectPreference(
            path: "/tmp/project",
            isEnabled: true,
            isHidden: false,
            customIconPath: nil,
            assignedSkillNames: ["lint"],
            assignedSkillCollectionIDs: [collectionID],
            assignedMcpServerNames: ["Pidgeon", "github"]
        )]
        suite.set(try JSONEncoder().encode(saved), forKey: key)

        let reloaded = ProjectPreferencesStore.loadPreferences(from: suite, key: key)
        let standardized = URL(fileURLWithPath: "/tmp/project").standardizedFileURL.path
        XCTAssertEqual(reloaded[standardized]?.assignedMcpServerNames, ["Pidgeon", "github"])
        // Sanity: skills and skill collections survive the same reconstruction path.
        XCTAssertEqual(reloaded[standardized]?.assignedSkillNames, ["lint"])
        XCTAssertEqual(reloaded[standardized]?.assignedSkillCollectionIDs, [collectionID])
    }

    @MainActor
    func testLegacyPreferenceWithoutMcpKeyDecodesToEmpty() throws {
        // A preference blob written before MCP existed must decode with an empty set.
        let legacy = #"{"path":"/p","isEnabled":true,"isFavorite":false,"isHidden":false,"assignedAgentNames":[],"assignedSkillNames":[],"assignedPromptTemplateNames":[]}"#
        let decoded = try JSONDecoder().decode(ProjectPreference.self, from: Data(legacy.utf8))
        XCTAssertTrue(decoded.assignedMcpServerNames.isEmpty)
    }

    // MARK: - Settings defaults

    @MainActor
    func testMCPSettingsDefaults() throws {
        let legacy = "{}"
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertFalse(settings.mcpEnabled)
        XCTAssertTrue(settings.defaultMcpServerNames.isEmpty)
        XCTAssertTrue(settings.computerUseNoProjectModes.isEmpty)
    }

    @MainActor
    func testComputerUseNoProjectModesRoundTrip() throws {
        var settings = AppSettings()
        settings.computerUseNoProjectModes = [.general, .agentDeckBuilder]
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.computerUseNoProjectModes, [.general, .agentDeckBuilder])
    }

    @MainActor
    func testAppSettingsDoesNotInferCollectionsFromImportedRepositories() throws {
        let repository = ImportedSkillRepository(
            id: UUID(),
            remoteURL: "https://github.com/PostHog/ai-plugin.git",
            owner: "PostHog",
            repo: "ai-plugin",
            ref: "main",
            clonePath: "/tmp/posthog-ai-plugin",
            syncedSkillRelativePaths: ["skills/a", "skills/b"],
            lastSyncedCommit: "abc123",
            lastSyncedDate: Date(timeIntervalSince1970: 1_700_000_000),
            lastCheckedDate: nil,
            latestKnownRemoteCommit: nil
        )
        let data = try JSONEncoder().encode([repository])
        let repositoriesJSON = try XCTUnwrap(String(data: data, encoding: .utf8))
        let json = "{\"importedSkillRepositories\":\(repositoriesJSON)}"
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.importedSkillRepositories, [repository])
        XCTAssertTrue(settings.skillCollections.isEmpty)
    }
}
