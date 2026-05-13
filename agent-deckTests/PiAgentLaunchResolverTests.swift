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

    func testProjectAssignmentOverridesDefaultAgentByName() {
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
        XCTAssertEqual(reviewer?.projectCustom?.filePath, "/tmp/project/.pi/agents/reviewer.md")
        XCTAssertEqual(reviewer?.resolutionKind, .projectCustom)
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
}

private extension ScanSnapshot {
    func replacing(projectRoot: String? = nil) -> ScanSnapshot {
        ScanSnapshot(
            projectRoot: projectRoot ?? self.projectRoot,
            builtinAgents: builtinAgents,
            globalAgents: globalAgents,
            projectAgents: projectAgents,
            legacyProjectAgents: legacyProjectAgents,
            effectiveAgents: effectiveAgents,
            libraryAgents: libraryAgents,
            skills: skills,
            librarySkills: librarySkills,
            promptTemplates: promptTemplates,
            libraryPromptTemplates: libraryPromptTemplates,
            settings: settings,
            envKeys: envKeys,
            warnings: warnings
        )
    }
}
