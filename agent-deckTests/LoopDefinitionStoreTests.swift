import XCTest
@testable import agent_deck

@MainActor
final class LoopDefinitionStoreTests: XCTestCase {
    func testLoopDefinitionPersistenceRoundTripsFrontmatterAndBody() throws {
        let directory = PiTestSupport.temporaryStateFile().deletingLastPathComponent().appendingPathComponent("loops", isDirectory: true)
        let store = LoopDefinitionStore(directoryURL: directory)
        let definition = LoopDefinition(
            name: "Research Notes",
            description: "Write a markdown report",
            goalTemplate: "Research this topic and produce Markdown.",
            maxIterations: 5,
            validationCommand: "swift test",
            availability: .projectPaths,
            projectPaths: ["/tmp/project-a"]
        )

        let saved = try store.saveUserDefinition(definition)
        XCTAssertTrue(saved.filePath?.hasSuffix("research-notes.loop.md") == true)

        let loaded = try XCTUnwrap(store.loadUserDefinitions().first)
        XCTAssertEqual(loaded.name, "Research Notes")
        XCTAssertEqual(loaded.description, "Write a markdown report")
        XCTAssertEqual(loaded.goalTemplate, "Research this topic and produce Markdown.")
        XCTAssertEqual(loaded.structure, .singleAgent)
        XCTAssertEqual(loaded.writeTarget, .artifactMarkdown)
        XCTAssertEqual(loaded.maxIterations, 5)
        XCTAssertEqual(loaded.validationCommand, "swift test")
        XCTAssertEqual(loaded.source, .user)
        XCTAssertEqual(loaded.availability, .projectPaths)
        XCTAssertEqual(loaded.projectPaths, ["/tmp/project-a"])
    }

    func testGoalEvaluationConfigRoundTrips() throws {
        let directory = PiTestSupport.temporaryStateFile().deletingLastPathComponent().appendingPathComponent("loops", isDirectory: true)
        let store = LoopDefinitionStore(directoryURL: directory)

        _ = try store.saveUserDefinition(LoopDefinition(
            name: "Evaluator Loop",
            goalTemplate: "Ship the feature",
            goalEvaluation: LoopGoalEvaluationConfig(successCondition: "Feature is implemented and tested", model: "openai/gpt-5", thinkingLevel: "low")
        ))

        let loaded = try XCTUnwrap(store.loadUserDefinitions().first)
        XCTAssertEqual(loaded.goalEvaluation.successCondition, "Feature is implemented and tested")
        XCTAssertEqual(loaded.goalEvaluation.model, "openai/gpt-5")
        XCTAssertEqual(loaded.goalEvaluation.thinkingLevel, "low")
        XCTAssertEqual(loaded.makeDraft().goalEvaluation.successCondition, "Feature is implemented and tested")
    }

    func testLaunchContextRoundTripsWithMultilineSafeEncoding() throws {
        let directory = PiTestSupport.temporaryStateFile().deletingLastPathComponent().appendingPathComponent("loops", isDirectory: true)
        let store = LoopDefinitionStore(directoryURL: directory)
        let context = "Line one\nLine two with --- and | delimiters\nLine three"

        _ = try store.saveUserDefinition(LoopDefinition(
            name: "Context Loop",
            goalTemplate: "Goal",
            launchContext: context,
            launchContextScope: .everyIteration
        ))

        let loaded = try XCTUnwrap(store.loadUserDefinitions().first)
        XCTAssertEqual(loaded.launchContext, context)
        XCTAssertEqual(loaded.launchContextScope, .everyIteration)
        XCTAssertEqual(loaded.makeDraft().launchContext, context)
        XCTAssertEqual(loaded.makeDraft().launchContextScope, .everyIteration)
    }

    func testProjectPathsWithFrontmatterDelimitersRoundTrip() throws {
        let directory = PiTestSupport.temporaryStateFile().deletingLastPathComponent().appendingPathComponent("loops", isDirectory: true)
        let store = LoopDefinitionStore(directoryURL: directory)
        let pathWithDelimiter = "/tmp/project|with-delimiter"

        _ = try store.saveUserDefinition(LoopDefinition(
            name: "Delimited Project",
            goalTemplate: "Goal",
            availability: .projectPaths,
            projectPaths: [pathWithDelimiter]
        ))

        let loaded = try XCTUnwrap(store.loadUserDefinitions().first)
        XCTAssertEqual(loaded.projectPaths, [pathWithDelimiter])
        XCTAssertTrue(loaded.isAvailable(in: pathWithDelimiter))
    }

    func testSlugCollisionsCreateDistinctDefinitionFiles() throws {
        let directory = PiTestSupport.temporaryStateFile().deletingLastPathComponent().appendingPathComponent("loops", isDirectory: true)
        let store = LoopDefinitionStore(directoryURL: directory)

        let first = try store.saveUserDefinition(LoopDefinition(name: "A/B", goalTemplate: "First"))
        let second = try store.saveUserDefinition(LoopDefinition(name: "A B", goalTemplate: "Second"))

        XCTAssertNotEqual(first.filePath, second.filePath)
        XCTAssertEqual(store.loadUserDefinitions().map(\.goalTemplate).sorted(), ["First", "Second"])
    }

    func testUpdateDuplicateAndDeleteUserDefinition() throws {
        let directory = PiTestSupport.temporaryStateFile().deletingLastPathComponent().appendingPathComponent("loops", isDirectory: true)
        let store = LoopDefinitionStore(directoryURL: directory)

        var saved = try store.saveUserDefinition(LoopDefinition(name: "Original", goalTemplate: "First"))
        saved.name = "Updated"
        saved.goalTemplate = "Second"
        let updated = try store.saveUserDefinition(saved)
        XCTAssertEqual(updated.filePath, saved.filePath)
        XCTAssertEqual(store.loadUserDefinitions().map(\.name), ["Updated"])

        let duplicate = try store.duplicateUserDefinition(updated)
        XCTAssertNotEqual(duplicate.filePath, updated.filePath)
        XCTAssertEqual(store.loadUserDefinitions().map(\.name).sorted(), ["Copy of Updated", "Updated"])

        try store.deleteUserDefinition(updated)
        XCTAssertEqual(store.loadUserDefinitions().map(\.name), ["Copy of Updated"])
    }

    func testSidebarIncludesLoopsInResourceSection() {
        XCTAssertTrue(SidebarItem.allCases.contains(.loops))
        XCTAssertTrue(SidebarSection.piResources.items.contains(.loops))
    }

    func testAppViewModelSlashUniverseIncludesCreateThenAvailableSavedLoops() throws {
        let directory = PiTestSupport.temporaryStateFile().deletingLastPathComponent().appendingPathComponent("loops", isDirectory: true)
        let store = LoopDefinitionStore(directoryURL: directory)
        _ = try store.saveUserDefinition(LoopDefinition(
            name: "Global Loop",
            description: "Everywhere",
            goalTemplate: "Global goal"
        ))
        _ = try store.saveUserDefinition(LoopDefinition(
            name: "Project Loop",
            description: "Only here",
            goalTemplate: "Project goal",
            availability: .projectPaths,
            projectPaths: ["/tmp/project-a"]
        ))
        _ = try store.saveUserDefinition(LoopDefinition(
            name: "Other Project Loop",
            goalTemplate: "Other goal",
            availability: .projectPaths,
            projectPaths: ["/tmp/project-b"]
        ))

        let viewModel = AppViewModel()
        viewModel.configureLoopDefinitionStoreForTesting(directoryURL: directory)
        let universe = viewModel.slashUniverse(forProjectPath: "/tmp/project-a")

        let userLoopNames = universe.loops.filter { $0.scopeLabel == "User" }.map(\.displayName)
        XCTAssertEqual(userLoopNames, ["Global Loop", "Project Loop"])
        XCTAssertTrue(universe.loops.dropFirst().allSatisfy { item in
            if case .loopDefinition = item.payload { return true }
            return false
        })
    }

    func testAppViewModelSavesMakerCheckerDraftConfiguration() throws {
        let directory = PiTestSupport.temporaryStateFile().deletingLastPathComponent().appendingPathComponent("loops", isDirectory: true)
        let viewModel = AppViewModel()
        viewModel.configureLoopDefinitionStoreForTesting(directoryURL: directory)
        let makerChecker = LoopMakerCheckerConfig(
            makerName: "Builder",
            checkerName: "Reviewer",
            checkerRubric: "reject once then approve"
        )

        _ = try viewModel.saveLoopDefinitionFromDraft(
            LoopDraft(goal: "Review this", structure: .makerChecker, makerChecker: makerChecker),
            request: LoopSaveRequest(name: "Review Loop", description: "", availability: .allProjects, projectPaths: [])
        )

        let saved = try XCTUnwrap(viewModel.loopDefinitions.first { $0.name == "Review Loop" })
        XCTAssertEqual(saved.structure, .makerChecker)
        XCTAssertEqual(saved.makerChecker, makerChecker)
        XCTAssertEqual(saved.makeDraft().makerChecker, makerChecker)
    }

    func testAppViewModelSaveRequestControlsLoopAvailability() throws {
        let directory = PiTestSupport.temporaryStateFile().deletingLastPathComponent().appendingPathComponent("loops", isDirectory: true)
        let viewModel = AppViewModel()
        viewModel.configureLoopDefinitionStoreForTesting(directoryURL: directory)

        let allProjects = try viewModel.saveLoopDefinitionFromDraft(
            LoopDraft(goal: "Global goal"),
            request: LoopSaveRequest(name: "Global", description: "", availability: .allProjects, projectPaths: ["/tmp/ignored"])
        )
        XCTAssertEqual(allProjects.availability, .allProjects)
        XCTAssertEqual(allProjects.projectPaths, [])
        XCTAssertTrue(allProjects.isAvailable(in: nil))
        XCTAssertTrue(allProjects.isAvailable(in: "/tmp/project-a"))

        let currentProject = try viewModel.saveLoopDefinitionFromDraft(
            LoopDraft(goal: "Project goal"),
            request: LoopSaveRequest(name: "Project", description: "", availability: .projectPaths, projectPaths: ["/tmp/project-a"])
        )
        XCTAssertEqual(currentProject.availability, .projectPaths)
        XCTAssertEqual(currentProject.projectPaths, ["/tmp/project-a"])
        XCTAssertTrue(currentProject.isAvailable(in: "/tmp/project-a"))
        XCTAssertFalse(currentProject.isAvailable(in: "/tmp/project-b"))

        let unassigned = try viewModel.saveLoopDefinitionFromDraft(
            LoopDraft(goal: "Catalog goal"),
            request: LoopSaveRequest(name: "Catalog", description: "", availability: .projectPaths, projectPaths: [])
        )
        XCTAssertEqual(unassigned.availability, .projectPaths)
        XCTAssertEqual(unassigned.projectPaths, [])
        XCTAssertFalse(unassigned.isAvailable(in: "/tmp/project-a"))
    }

    func testNewLoopAgentDefaultsRemainBlankUntilUserSelectsAgent() throws {
        let draft = LoopDraft()
        XCTAssertEqual(draft.makerChecker.makerName, "")
        XCTAssertEqual(draft.makerChecker.checkerName, "")
        XCTAssertEqual(draft.discoveryTriage.agentName, "")
        XCTAssertEqual(draft.pipeline.stageNames, [])

        let directory = PiTestSupport.temporaryStateFile().deletingLastPathComponent().appendingPathComponent("loops", isDirectory: true)
        let store = LoopDefinitionStore(directoryURL: directory)
        let url = directory.appendingPathComponent("blank-agent.loop.md")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        ---
        name: Blank Agent
        description:
        source: user
        structure: singleAgent
        writeTarget: artifactMarkdown
        maxIterations: 3
        availability: allProjects
        ---

        Goal
        """.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try XCTUnwrap(store.loadUserDefinitions().first)
        XCTAssertEqual(loaded.makerChecker.makerName, "")
        XCTAssertEqual(loaded.makerChecker.checkerName, "")
        XCTAssertEqual(loaded.discoveryTriage.agentName, "")
    }

    func testSavedLoopConvertsToFreshLaunchDraft() {
        let definition = LoopDefinition(
            name: "Reusable",
            goalTemplate: "Use this saved goal",
            launchContext: "Keep this context",
            launchContextScope: .everyIteration,
            maxIterations: 7,
            validationCommand: "swift test"
        )

        let draft = definition.makeDraft()
        XCTAssertEqual(draft.goal, "Use this saved goal")
        XCTAssertEqual(draft.structure, .singleAgent)
        XCTAssertEqual(draft.writeTarget, .artifactMarkdown)
        XCTAssertEqual(draft.maxIterations, 7)
        XCTAssertEqual(draft.validationCommand, "swift test")
        XCTAssertEqual(draft.launchContext, "Keep this context")
        XCTAssertEqual(draft.launchContextScope, .everyIteration)
    }

    func testLoopDefinitionExactRunMatchIncludesLaunchContextAndScope() {
        let definition = LoopDefinition(
            name: "Context Sensitive",
            goalTemplate: "Same goal",
            launchContext: "Use these notes",
            launchContextScope: .everyIteration,
            validationCommand: "swift test"
        )
        let matchingRun = LoopRun(sessionID: UUID(), projectPath: nil, draft: definition.makeDraft())
        var differentContext = matchingRun
        differentContext.launchContext = "Different notes"
        var missingContext = matchingRun
        missingContext.launchContext = nil
        var differentScope = matchingRun
        differentScope.launchContextScope = .firstIterationOnly

        XCTAssertTrue(definition.exactlyMatches(run: matchingRun))
        XCTAssertFalse(definition.exactlyMatches(run: differentContext))
        XCTAssertFalse(definition.exactlyMatches(run: missingContext))
        XCTAssertFalse(definition.exactlyMatches(run: differentScope))
    }

    func testNoBuiltInTemplatesLoadIntoLoopBankAndSlashUniverse() throws {
        let directory = PiTestSupport.temporaryStateFile().deletingLastPathComponent().appendingPathComponent("loops", isDirectory: true)
        let viewModel = AppViewModel()
        viewModel.configureLoopDefinitionStoreForTesting(directoryURL: directory)

        XCTAssertTrue(viewModel.loopDefinitions.filter { $0.source == .builtin }.isEmpty)
        let universe = viewModel.slashUniverse(forProjectPath: "/tmp/project-a")
        XCTAssertFalse(universe.loops.contains { $0.scopeLabel == "Built-in" })
    }
}
