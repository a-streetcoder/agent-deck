import XCTest
@testable import agent_deck

@MainActor
final class PiSkillVisibilitySmokeTests: XCTestCase {
    func testParentSessionGetsRuntimeSkillCommandsFromPiRPC() throws {
        let harness = try PiTestSupport.makeBridgeHarness(event: [
            "type": "response",
            "command": "get_commands",
            "success": true,
            "data": [
                "commands": [
                    "/ship",
                    "/skill:global-skill",
                    "/skill:project-skill"
                ]
            ]
        ])
        defer { harness.restoreEnvironment() }

        let projectURL = try PiTestSupport.temporaryProjectURL()
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        let session = store.createSession(
            kind: .project,
            title: "Parent",
            project: try PiTestSupport.makeProject(url: projectURL),
            repository: nil
        )

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id, recordTranscript: false) }

        XCTAssertTrue(PiTestSupport.waitUntil {
            store.sessions.first(where: { $0.id == session.id })?.commandInvocations?.contains("/skill:global-skill") == true
        })
        let invocations = store.sessions.first(where: { $0.id == session.id })?.commandInvocations ?? []
        XCTAssertTrue(invocations.contains("/ship"))
        XCTAssertTrue(invocations.contains("/skill:project-skill"))
    }

    func testParentLaunchDisablesAmbientSkillsWhenNoAssignmentsExist() throws {
        let fakePi = try PiTestSupport.makeFakePiExecutable()
        let oldPiPath = getenv("AGENT_DECK_PI_PATH").map { String(cString: $0) }
        setenv("AGENT_DECK_PI_PATH", fakePi.path, 1)
        defer { restorePiPath(oldPiPath) }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        let session = store.createSession(
            kind: .project,
            title: "Parent",
            project: try PiTestSupport.makeProject(),
            repository: nil
        )

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id, recordTranscript: false) }

        XCTAssertTrue(PiTestSupport.waitUntil {
            store.sessions.first(where: { $0.id == session.id })?.launchCommand != nil
        })
        let launchCommand = store.sessions.first(where: { $0.id == session.id })?.launchCommand ?? ""
        XCTAssertTrue(launchCommand.contains("--no-skills"))
        XCTAssertFalse(launchCommand.contains("--skill"))
        XCTAssertTrue(launchCommand.contains("--no-prompt-templates"))
        XCTAssertFalse(launchCommand.contains("--prompt-template"))
        XCTAssertTrue(launchCommand.contains("--no-themes"))
        XCTAssertFalse(launchCommand.contains("skill-library"))
    }

    func testParentLaunchPassesAssignedSkillsWithNativeSkillFlag() throws {
        let skill = SkillRecord(
            id: "catalog:default-skill",
            name: "default-skill",
            description: "Default skill",
            source: ScopeID(kind: .global, path: "/tmp/default-skill/SKILL.md"),
            filePath: "/tmp/default-skill/SKILL.md",
            body: "# Default Skill"
        )

        let args = try PiSkillLaunchResolver.parentSkillArguments(defaultSkillNames: ["default-skill"], projectSkillNames: [], snapshot: .empty.replacing(skills: [skill]))
        XCTAssertEqual(args, ["--skill", "/tmp/default-skill/SKILL.md"])
    }

    func testParentLaunchSkipsMissingAssignedSkills() throws {
        let skill = SkillRecord(
            id: "catalog:available-skill",
            name: "available-skill",
            description: "Available skill",
            source: ScopeID(kind: .global, path: "/tmp/available-skill/SKILL.md"),
            filePath: "/tmp/available-skill/SKILL.md",
            body: "# Available Skill"
        )

        let args = try PiSkillLaunchResolver.parentSkillArguments(
            defaultSkillNames: ["available-skill", "deleted-skill"],
            projectSkillNames: [],
            snapshot: .empty.replacing(skills: [skill])
        )
        XCTAssertEqual(args, ["--skill", "/tmp/available-skill/SKILL.md"])
    }

    func testExternalSkillPathIsScannedAsLibraryCatalogSkillWithoutCopying() throws {
        let skillRoot = FileManager.default.temporaryDirectory.appendingPathComponent("agent-deck-external-skill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
        let skillFile = skillRoot.appendingPathComponent("SKILL.md")
        try """
        ---
        name: external-review
        description: Review from external source.
        ---

        # External Review
        """.write(to: skillFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: skillRoot) }

        let snapshot = PiScanner(externalSkillPaths: [skillRoot.path]).scan(projectRoot: nil)
        let skill = try XCTUnwrap(snapshot.librarySkills.first { $0.name == "external-review" })

        XCTAssertEqual(URL(fileURLWithPath: skill.filePath).standardizedFileURL.path, skillFile.standardizedFileURL.path)
        XCTAssertEqual(skill.source.kind, .library)
        XCTAssertEqual(try PiSkillLaunchResolver.skillArguments(for: ["external-review"], catalog: PiSkillLaunchResolver.catalog(from: snapshot)), ["--skill", skillFile.path])
    }

    func testParentLaunchPassesAssignedPromptsWithNativePromptTemplateFlag() throws {
        let prompt = PromptTemplateRecord(
            id: "catalog:review-prompt",
            name: "review-prompt",
            description: "Review prompt",
            argumentHint: nil,
            source: ScopeID(kind: .global, path: "/tmp/review-prompt.md"),
            filePath: "/tmp/review-prompt.md",
            body: "Review $ARGUMENTS",
            discoveryKind: .standardDirectory,
            packageName: nil
        )

        let args = try PiPromptTemplateLaunchResolver.promptTemplateArguments(for: ["/review-prompt"], catalog: [prompt])
        XCTAssertEqual(args, ["--prompt-template", "/tmp/review-prompt.md"])
    }

    func testParentLaunchSkipsMissingAssignedPromptsWhenRequested() throws {
        let prompt = PromptTemplateRecord(
            id: "catalog:available-prompt",
            name: "available-prompt",
            description: "Available prompt",
            argumentHint: nil,
            source: ScopeID(kind: .global, path: "/tmp/available-prompt.md"),
            filePath: "/tmp/available-prompt.md",
            body: "Use available prompt.",
            discoveryKind: .standardDirectory,
            packageName: nil
        )

        let args = try PiPromptTemplateLaunchResolver.promptTemplateArguments(
            for: ["available-prompt", "deleted-prompt"],
            catalog: [prompt],
            missingPromptPolicy: .skip
        )
        XCTAssertEqual(args, ["--prompt-template", "/tmp/available-prompt.md"])
    }

    func testPromptLaunchStillFailsMissingAssignedPromptsByDefault() throws {
        XCTAssertThrowsError(try PiPromptTemplateLaunchResolver.promptTemplateArguments(for: ["deleted-prompt"], catalog: [])) { error in
            XCTAssertTrue(error.localizedDescription.contains("deleted-prompt"))
        }
    }

    func testNativeSubagentPassesExplicitSkillUsingNativeSkillFlag() async throws {
        let fakePi = try PiTestSupport.makeFakePiExecutable()
        let oldPiPath = getenv("AGENT_DECK_PI_PATH").map { String(cString: $0) }
        setenv("AGENT_DECK_PI_PATH", fakePi.path, 1)
        defer { restorePiPath(oldPiPath) }

        let skill = SkillRecord(
            id: "library:library-only",
            name: "library-only",
            description: "Library skill",
            source: ScopeID(kind: .library, path: "/tmp/library-only/SKILL.md"),
            filePath: "/tmp/library-only/SKILL.md",
            body: "# Library Only Skill\nUse private instructions."
        )
        let snapshot = ScanSnapshot.empty.replacing(librarySkills: [skill])
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession()

        let run = try await runner.runSingle(
            parentSession: parent,
            agent: PiTestSupport.makeAgent(skills: ["library-only"]),
            snapshot: snapshot,
            task: "Use the private skill."
        )
        defer { runner.stop(runID: run.id, parentSessionID: parent.id) }

        let launchCommand = try XCTUnwrap(run.launchCommand)
        XCTAssertTrue(launchCommand.contains("--no-skills"))
        XCTAssertTrue(launchCommand.contains("--skill /tmp/library-only/SKILL.md"))
        let systemPrompt = try String(contentsOf: URL(fileURLWithPath: run.artifactDirectory).appendingPathComponent("system-prompt.md"), encoding: .utf8)
        XCTAssertFalse(systemPrompt.contains("Use private instructions."))
    }

    func testNativeSubagentAlwaysDisablesAmbientSkillDiscovery() async throws {
        let fakePi = try PiTestSupport.makeFakePiExecutable()
        let oldPiPath = getenv("AGENT_DECK_PI_PATH").map { String(cString: $0) }
        setenv("AGENT_DECK_PI_PATH", fakePi.path, 1)
        defer { restorePiPath(oldPiPath) }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession()

        let inherited = try await runner.runSingle(
            parentSession: parent,
            agent: PiTestSupport.makeAgent(),
            snapshot: .empty,
            task: "Do not use ambient skills."
        )
        defer { runner.stop(runID: inherited.id, parentSessionID: parent.id) }
        XCTAssertTrue(inherited.launchCommand?.contains("--no-skills") == true)
        XCTAssertTrue(inherited.launchCommand?.contains("--no-prompt-templates") == true)
        XCTAssertTrue(inherited.launchCommand?.contains("--no-themes") == true)
    }

    func testNativeSubagentBlocksMissingExplicitSkill() async throws {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession()

        do {
            _ = try await runner.runSingle(
                parentSession: parent,
                agent: PiTestSupport.makeAgent(skills: ["missing-skill"]),
                snapshot: .empty,
                task: "Launch anyway."
            )
            XCTFail("Expected runSingle to throw for missing skill.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("missing-skill"))
        }
    }

    func testNativeSubagentBlocksAssignedSkillsWithoutReadTool() async throws {
        let skill = SkillRecord(
            id: "catalog:agent-skill",
            name: "agent-skill",
            description: "Agent skill",
            source: ScopeID(kind: .global, path: "/tmp/agent-skill/SKILL.md"),
            filePath: "/tmp/agent-skill/SKILL.md",
            body: "# Agent Skill"
        )
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession()

        do {
            _ = try await runner.runSingle(
                parentSession: parent,
                agent: PiTestSupport.makeAgent(tools: ["contact_supervisor"], skills: ["agent-skill"]),
                snapshot: .empty.replacing(skills: [skill]),
                task: "Use skill without read."
            )
            XCTFail("Expected runSingle to throw for skill without read tool.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("read"))
        }
    }
}

private extension ScanSnapshot {
    func replacing(skills: [SkillRecord]? = nil, librarySkills: [SkillRecord]? = nil) -> ScanSnapshot {
        ScanSnapshot(
            projectRoot: projectRoot,
            builtinAgents: builtinAgents,
            globalAgents: globalAgents,
            projectAgents: projectAgents,
            legacyProjectAgents: legacyProjectAgents,
            effectiveAgents: effectiveAgents,
            libraryAgents: libraryAgents,
            skills: skills ?? self.skills,
            librarySkills: librarySkills ?? self.librarySkills,
            promptTemplates: promptTemplates,
            libraryPromptTemplates: libraryPromptTemplates,
            settings: settings,
            envKeys: envKeys,
            warnings: warnings
        )
    }
}

private func restorePiPath(_ oldPiPath: String?) {
    if let oldPiPath {
        setenv("AGENT_DECK_PI_PATH", oldPiPath, 1)
    } else {
        unsetenv("AGENT_DECK_PI_PATH")
    }
}
