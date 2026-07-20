import XCTest
@testable import agent_deck

final class PiAgentLaunchResolverTests: XCTestCase {
    @MainActor
    func testBuiltinOverrideSkillReferenceReplacementChangesOnlyMatchingSkills() throws {
        let root: [String: Any] = [
            "unrelated": ["kept": true],
            "subagents": [
                "agentOverrides": [
                    "explorer": ["skills": ["old-skill", "other-skill"]],
                    "coder": ["skills": "old-skill"]
                ]
            ]
        ]

        let updated = try XCTUnwrap(AppViewModel.replacingBuiltinOverrideSkillReferences(in: root, from: "old-skill", to: "new-skill"))
        let subagents = try XCTUnwrap(updated["subagents"] as? [String: Any])
        let overrides = try XCTUnwrap(subagents["agentOverrides"] as? [String: Any])
        let explorer = try XCTUnwrap(overrides["explorer"] as? [String: Any])
        let coder = try XCTUnwrap(overrides["coder"] as? [String: Any])
        XCTAssertEqual(explorer["skills"] as? [String], ["new-skill", "other-skill"])
        XCTAssertEqual(coder["skills"] as? String, "new-skill")
        XCTAssertEqual((updated["unrelated"] as? [String: Bool])?["kept"], true)
    }

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

    func testProjectFallbackResolvesRequestedProjectAssignmentsWithoutLeakingDisplayedAgents() {
        let builtins = [
            agentRecord(name: "explorer", kind: .builtin, path: "/app/explorer.md"),
            agentRecord(name: "planner", kind: .builtin, path: "/app/planner.md"),
            agentRecord(name: "reviewer", kind: .builtin, path: "/app/reviewer.md")
        ]
        let appleDesigner = agentRecord(name: "apple-designer-expert", kind: .global, path: "/global/apple-designer-expert.md")
        let ponytail = agentRecord(name: "ponytail", kind: .global, path: "/global/ponytail.md")
        let displayedAgents = PiAgentLaunchResolver.effectiveAgents(
            defaultAgentNames: ["apple-designer-expert"],
            projectAgentNames: [],
            snapshot: .empty.replacing(projectRoot: "/projects/displayed", builtinAgents: builtins),
            catalog: [appleDesigner, ponytail]
        )
        let globalSnapshot = ScanSnapshot.empty.replacing(
            builtinAgents: builtins,
            globalAgents: [appleDesigner, ponytail],
            effectiveAgents: displayedAgents
        )

        let fallback = PiAgentLaunchResolver.projectFallbackSnapshot(
            from: globalSnapshot,
            projectRoot: "/projects/requested"
        )
        let resolved = PiAgentLaunchResolver.effectiveAgents(
            defaultAgentNames: [],
            projectAgentNames: ["ponytail"],
            snapshot: fallback,
            catalog: fallback.globalAgents + fallback.libraryAgents
        )

        XCTAssertEqual(fallback.projectRoot, "/projects/requested")
        XCTAssertTrue(fallback.effectiveAgents.isEmpty)
        XCTAssertEqual(Set(resolved.map(\.name)), ["explorer", "planner", "ponytail", "reviewer"])
        XCTAssertFalse(resolved.contains { $0.name == "apple-designer-expert" })
        XCTAssertTrue(resolved.allSatisfy { $0.projectRoot == "/projects/requested" })
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

    func testProjectBuiltinSubagentConfigurationIsIgnored() {
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
                        "thinking": .string("medium"),
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
                        "model": .string("project/ignored"),
                        "skills": .array([.string("project-only-skill")]),
                        "thinking": .bool(false)
                    ]
                )
            ],
            disableBuiltins: true
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
        XCTAssertEqual(explorer?.resolved.thinking, "medium")
        XCTAssertEqual(explorer?.resolved.skills, ["agent-authoring"])
        XCTAssertNil(explorer?.projectOverride)
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
        globalAgents: [AgentRecord]? = nil,
        effectiveAgents: [EffectiveAgentRecord]? = nil,
        settings: [SettingsSummary]? = nil
    ) -> ScanSnapshot {
        ScanSnapshot(
            projectRoot: projectRoot ?? self.projectRoot,
            builtinAgents: builtinAgents ?? self.builtinAgents,
            globalAgents: globalAgents ?? self.globalAgents,
            projectAgents: projectAgents,
            legacyProjectAgents: legacyProjectAgents,
            effectiveAgents: effectiveAgents ?? self.effectiveAgents,
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
