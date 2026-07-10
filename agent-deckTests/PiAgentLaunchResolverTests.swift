import XCTest
@testable import agent_deck

final class PiAgentLaunchResolverTests: XCTestCase {
    func testUnassignedCustomAgentsStayCatalogOnly() {
        let custom = agentRecord(name: "coder", kind: .global, path: "/tmp/coder.md")
        let snapshot = ScanSnapshot.empty
        let effective = PiAgentLaunchResolver.effectiveAgents(
            defaultAgentNames: [],
            projectAgentNames: [],
            snapshot: snapshot,
            catalog: [custom]
        )

        XCTAssertFalse(effective.contains { $0.name == "coder" })
    }

    func testDefaultAgentAssignmentMakesCatalogAgentEffective() {
        let custom = agentRecord(name: "coder", kind: .global, path: "/tmp/coder.md")
        let effective = PiAgentLaunchResolver.effectiveAgents(
            defaultAgentNames: ["coder"],
            projectAgentNames: [],
            snapshot: .empty,
            catalog: [custom]
        )

        let coder = effective.first { $0.name == "coder" }
        XCTAssertEqual(coder?.globalCustom?.filePath, "/tmp/coder.md")
        XCTAssertEqual(coder?.resolutionKind, .globalCustom)
    }

    func testProjectAssignmentUsesGlobalCatalogAgentByName() {
        let global = agentRecord(name: "reviewer", kind: .global, path: "/tmp/global-reviewer.md")
        let project = agentRecord(name: "reviewer", kind: .project, path: "/tmp/project/.pi/agents/reviewer.md")
        let snapshot = ScanSnapshot.empty.replacing(projectRoot: "/tmp/project")

        let effective = PiAgentLaunchResolver.effectiveAgents(
            defaultAgentNames: ["reviewer"],
            projectAgentNames: ["reviewer"],
            snapshot: snapshot,
            catalog: [global, project]
        )

        let reviewer = effective.first { $0.name == "reviewer" }
        XCTAssertEqual(reviewer?.globalCustom?.filePath, "/tmp/global-reviewer.md")
        XCTAssertNil(reviewer?.projectCustom)
        XCTAssertEqual(reviewer?.resolutionKind, .globalCustom)
    }

    func testProjectBuiltinOverrideMergesGlobalModelOverride() {
        let projectRoot = "/tmp/project"
        let builtin = agentRecord(name: "explorer", kind: .builtin, path: "/app/bundled-agents/explorer.md")
        let globalSettings = settingsSummary(
            path: "/Users/test/.pi/agent/settings.json",
            overrides: [
                override(
                    name: "explorer",
                    path: "/Users/test/.pi/agent/settings.json",
                    values: [
                        "model": .string("openai-codex/gpt-5.4-mini"),
                        "thinking": .bool(false),
                        "skills": .array([.string("agent-authoring")])
                    ]
                )
            ]
        )
        let projectSettings = settingsSummary(
            path: "\(projectRoot)/.pi/settings.json",
            overrides: [
                override(
                    name: "explorer",
                    path: "\(projectRoot)/.pi/settings.json",
                    values: [
                        "skills": .array([.string("agent-authoring")]),
                        "thinking": .bool(false)
                    ]
                )
            ]
        )
        let snapshot = ScanSnapshot.empty.replacing(
            projectRoot: projectRoot,
            builtinAgents: [builtin],
            settings: [globalSettings, projectSettings]
        )

        let effective = PiAgentLaunchResolver.effectiveAgents(
            defaultAgentNames: [],
            projectAgentNames: [],
            snapshot: snapshot,
            catalog: []
        )

        let explorer = effective.first { $0.name == "explorer" }
        XCTAssertEqual(explorer?.resolved.model, "openai-codex/gpt-5.4-mini")
        XCTAssertEqual(explorer?.resolved.thinking, "off")
        XCTAssertEqual(explorer?.resolved.skills, ["agent-authoring"])
        XCTAssertEqual(explorer?.resolutionKind, .builtinWithOverride)
    }

    private func agentRecord(name: String, kind: ResourceScopeKind, path: String) -> AgentRecord {
        var config = AgentConfig.empty
        config.name = name
        config.description = name
        config.systemPrompt = "You are \(name)."
        return AgentRecord(
            id: "\(kind.rawValue):\(path)",
            name: name,
            description: name,
            source: ScopeID(kind: kind, path: path),
            filePath: path,
            rawFrontmatter: [:],
            promptBody: config.systemPrompt,
            parsed: config
        )
    }

    private func settingsSummary(path: String, overrides: [BuiltinOverrideRecord], disableBuiltins: Bool? = nil) -> SettingsSummary {
        SettingsSummary(path: path, packages: [], prompts: [], disableBuiltins: disableBuiltins, agentOverrides: overrides)
    }

    private func override(name: String, path: String, values: [String: JSONValue]) -> BuiltinOverrideRecord {
        BuiltinOverrideRecord(
            agentName: name,
            scope: ScopeID(kind: .override, path: path),
            settingsPath: path,
            values: values
        )
    }
}

private extension ScanSnapshot {
    func replacing(
        projectRoot: String? = nil,
        builtinAgents: [AgentRecord]? = nil,
        settings: [SettingsSummary]? = nil
    ) -> ScanSnapshot {
        ScanSnapshot(
            projectRoot: projectRoot ?? self.projectRoot,
            builtinAgents: builtinAgents ?? self.builtinAgents,
            globalAgents: globalAgents,
            projectAgents: projectAgents,
            legacyProjectAgents: legacyProjectAgents,
            effectiveAgents: effectiveAgents,
            libraryAgents: libraryAgents,
            skills: skills,
            librarySkills: librarySkills,
            promptTemplates: promptTemplates,
            libraryPromptTemplates: libraryPromptTemplates,
            settings: settings ?? self.settings,
            envKeys: envKeys,
            warnings: warnings
        )
    }
}
