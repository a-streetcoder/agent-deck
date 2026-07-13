import XCTest
@testable import agent_deck

final class ComputerUseCapabilityTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        super.tearDown()
    }

    private func rawSkillFixture() throws -> (raw: URL, copied: URL, user: URL, package: CodexPluginSkillDiscovery.Package) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("computer-use-\(UUID())", isDirectory: true)
        roots.append(root)
        let pluginRoot = root.appendingPathComponent("plugin", isDirectory: true)
        let skillsRoot = pluginRoot.appendingPathComponent("skills", isDirectory: true)
        let raw = skillsRoot.appendingPathComponent("computer-use", isDirectory: true)
        let copied = root.appendingPathComponent("copied-computer-use", isDirectory: true)
        let user = root.appendingPathComponent("user-computer-use", isDirectory: true)
        for directory in [raw, copied, user] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "---\nname: computer-use\n---\nraw".write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        let package = CodexPluginSkillDiscovery.Package(
            identity: .init(marketplace: "openai-bundled", plugin: "computer-use"),
            version: "1.0.0",
            root: pluginRoot,
            skillsRoot: skillsRoot,
            displayName: "Computer Use"
        )
        return (raw, copied, user, package)
    }

    private func pluginEntry(available: Bool = true) -> MCPServerEntry {
        MCPServerEntry(
            name: ComputerUseCapability.serverName,
            config: MCPServerConfig(command: "/plugin/helper"),
            sourcePath: "/plugin/.mcp.json",
            provenance: .codexPlugin(version: "1.0", availability: "Available"),
            toolPolicy: .computerUseObservationOnly,
            availabilityDiagnostic: available ? nil : "disabled"
        )
    }

    func testGuideIsInjectedAtEachMCPAssignmentScopeExactlyOnce() {
        let catalog = "MCP tools (call through the `mcp` proxy tool):\n- codex-computer-use/list_apps"
        let scopes: [(String, Set<String>)] = [
            ("global parent", [ComputerUseCapability.serverName]),
            ("project parent", [ComputerUseCapability.serverName]),
            ("bound agent", [ComputerUseCapability.serverName]),
            ("delegated agent", [ComputerUseCapability.serverName])
        ]
        for (name, scope) in scopes {
            let prompt = ComputerUseCapability.appendGuide(to: catalog, scope: scope, entries: [pluginEntry()], catalogEntries: [.init(server: ComputerUseCapability.serverName, tool: "list_apps", description: nil)])
            XCTAssertEqual(prompt?.components(separatedBy: "Computer Use (observation-only):").count, 2, name)
            XCTAssertTrue(prompt?.contains("mcp({ tool: \"codex-computer-use/list_apps\", args: {} })") == true, name)
        }
    }

    func testGuideIsNotInjectedWhenUnassignedUnavailableOrCollided() {
        let catalogEntries: [MCPCatalogEntry] = [.init(server: ComputerUseCapability.serverName, tool: "list_apps", description: nil)]
        XCTAssertEqual(ComputerUseCapability.appendGuide(to: "catalog", scope: [], entries: [pluginEntry()], catalogEntries: catalogEntries), "catalog")
        XCTAssertEqual(ComputerUseCapability.appendGuide(to: "catalog", scope: [ComputerUseCapability.serverName], entries: [pluginEntry(available: false)], catalogEntries: catalogEntries), "catalog")
        XCTAssertEqual(ComputerUseCapability.appendGuide(to: "catalog", scope: [ComputerUseCapability.serverName], entries: [pluginEntry()], catalogEntries: []), "catalog")
        let collision = MCPServerEntry(name: ComputerUseCapability.serverName, config: MCPServerConfig(command: "user-server"), sourcePath: "/user/mcp.json")
        XCTAssertEqual(ComputerUseCapability.appendGuide(to: "catalog", scope: [ComputerUseCapability.serverName], entries: [collision], catalogEntries: catalogEntries), "catalog")
    }

    func testInstalledRawSkillIsBlockedButCopiedAndUserSkillsRemainImportable() throws {
        let fixture = try rawSkillFixture()
        XCTAssertTrue(ComputerUseCapability.isInstalledRawSkill(at: fixture.raw, packages: [fixture.package]))
        XCTAssertFalse(ComputerUseCapability.isInstalledRawSkill(at: fixture.copied, packages: [fixture.package]))
        XCTAssertFalse(ComputerUseCapability.isInstalledRawSkill(at: fixture.user, packages: [fixture.package]))
        XCTAssertNotNil(ExternalSkillDiscovery.candidate(at: fixture.user))
    }

    @MainActor
    func testRefreshSkipsOnlyInstalledRawExternalPath() throws {
        let fixture = try rawSkillFixture()
        let snapshot = AppRefreshService().loadSnapshot(
            rootURLs: [], selectedProjectPath: nil, preferencesByPath: [:],
            externalSkillPaths: [fixture.raw.path, fixture.user.path], externalPromptPaths: [],
            codexPluginPackages: [fixture.package]
        )
        XCTAssertFalse(snapshot.globalSnapshot.librarySkills.contains { $0.filePath.hasPrefix(fixture.raw.path) })
        XCTAssertTrue(snapshot.globalSnapshot.librarySkills.contains { $0.filePath.hasPrefix(fixture.user.path) })
    }

    @MainActor
    func testLegacyMigrationPersistsAcrossRestartAndDoesNotMaskUserSkill() throws {
        let reference = CodexPluginSkillReference(marketplace: "openai-bundled", plugin: "computer-use", relativeSkillRoot: "skills/computer-use")
        var settings = AppSettings()
        settings.codexPluginSkillReferences = [reference]
        settings.legacyComputerUseSkillNames = ComputerUseCapability.legacySkillNames(for: [reference])
        settings.codexPluginSkillReferences.remove(reference)
        let restarted = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(restarted.legacyComputerUseSkillNames.contains("computer-use"))

        let restrictive = PiTestSupport.makeAgent(tools: ["bash"], skills: ["computer-use"])
        XCTAssertEqual(try PiSkillLaunchResolver.childSkillArguments(agent: restrictive, snapshot: .empty, ignoredMissingSkillNames: restarted.legacyComputerUseSkillNames), [])

        let userSkill = SkillRecord(id: "user", name: "computer-use", description: nil, source: .init(kind: .global, path: "/user/SKILL.md"), filePath: "/user/SKILL.md", body: "")
        let userSnapshot = ScanSnapshot(projectRoot: nil, builtinAgents: [], globalAgents: [], projectAgents: [], legacyProjectAgents: [], effectiveAgents: [], libraryAgents: [], skills: [userSkill], librarySkills: [], promptTemplates: [], libraryPromptTemplates: [], settings: [], envKeys: [], warnings: [])
        let userAgent = PiTestSupport.makeAgent(tools: ["read"], skills: ["computer-use"])
        XCTAssertEqual(try PiSkillLaunchResolver.childSkillArguments(agent: userAgent, snapshot: userSnapshot, ignoredMissingSkillNames: restarted.legacyComputerUseSkillNames), ["--skill", "/user/SKILL.md"])
    }
}
