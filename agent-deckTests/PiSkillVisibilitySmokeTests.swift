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

    func testParentLaunchDoesNotPassLibrarySkillsAsExplicitSkillArguments() throws {
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
        XCTAssertFalse(launchCommand.contains("--skill"))
        XCTAssertFalse(launchCommand.contains("skill-library"))
    }

    func testNativeSubagentInjectsExplicitLibrarySkillBlocks() throws {
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

        let run = try runner.runSingle(
            parentSession: parent,
            agent: PiTestSupport.makeAgent(skills: ["library-only"]),
            snapshot: snapshot,
            task: "Use the private skill.",
            requestedContext: .fresh
        )
        defer { runner.stop(runID: run.id, parentSessionID: parent.id) }

        let systemPrompt = try String(contentsOf: URL(fileURLWithPath: run.artifactDirectory).appendingPathComponent("system-prompt.md"), encoding: .utf8)
        XCTAssertTrue(systemPrompt.contains("library-only"))
        XCTAssertTrue(systemPrompt.contains("Use private instructions."))
        XCTAssertNil(run.child?.error)
    }

    func testNativeSubagentCanKeepAmbientSkillDiscoveryWhenInherited() throws {
        let fakePi = try PiTestSupport.makeFakePiExecutable()
        let oldPiPath = getenv("AGENT_DECK_PI_PATH").map { String(cString: $0) }
        setenv("AGENT_DECK_PI_PATH", fakePi.path, 1)
        defer { restorePiPath(oldPiPath) }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession()

        let inherited = try runner.runSingle(
            parentSession: parent,
            agent: PiTestSupport.makeAgent(inheritSkills: true),
            snapshot: .empty,
            task: "Keep ambient skills.",
            requestedContext: .fresh
        )
        defer { runner.stop(runID: inherited.id, parentSessionID: parent.id) }
        XCTAssertFalse(inherited.launchCommand?.contains("--no-skills") == true)

        let isolated = try runner.runSingle(
            parentSession: parent,
            agent: PiTestSupport.makeAgent(inheritSkills: false),
            snapshot: .empty,
            task: "Disable ambient skills.",
            requestedContext: .fresh
        )
        defer { runner.stop(runID: isolated.id, parentSessionID: parent.id) }
        XCTAssertTrue(isolated.launchCommand?.contains("--no-skills") == true)
    }

    func testNativeSubagentReportsMissingExplicitSkillButStillLaunches() throws {
        let fakePi = try PiTestSupport.makeFakePiExecutable()
        let oldPiPath = getenv("AGENT_DECK_PI_PATH").map { String(cString: $0) }
        setenv("AGENT_DECK_PI_PATH", fakePi.path, 1)
        defer { restorePiPath(oldPiPath) }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiSubagentRunService(store: store)
        let parent = try PiTestSupport.makeParentSession()

        let run = try runner.runSingle(
            parentSession: parent,
            agent: PiTestSupport.makeAgent(skills: ["missing-skill"]),
            snapshot: .empty,
            task: "Launch anyway.",
            requestedContext: .fresh
        )
        defer { runner.stop(runID: run.id, parentSessionID: parent.id) }

        XCTAssertTrue(run.error?.contains("Skill not found: missing-skill") == true)
        let systemPrompt = try String(contentsOf: URL(fileURLWithPath: run.artifactDirectory).appendingPathComponent("system-prompt.md"), encoding: .utf8)
        XCTAssertFalse(systemPrompt.contains("missing-skill"))
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
            chains: chains,
            libraryAgents: libraryAgents,
            libraryChains: libraryChains,
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
