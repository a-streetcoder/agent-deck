import Foundation

// MARK: - Loop definitions

extension AppViewModel {
    func reloadLoopDefinitions() {
        loopDefinitions = loopDefinitionStore.loadDefinitions()
        if let selectedLoopDefinitionID,
           !loopDefinitions.contains(where: { $0.id == selectedLoopDefinitionID }) {
            self.selectedLoopDefinitionID = loopDefinitions.first?.id
        }
    }

    func loopDefinitionForLaunch(_ definition: LoopDefinition) -> LoopDefinition {
        guard definition.source == .user,
              let filePath = definition.filePath?.nonEmpty ?? definition.id.nonEmpty else {
            return definition
        }
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: url.path),
              let current = try? LoopDefinitionStore.decodeDefinition(at: url, source: .user) else {
            return definition
        }
        if let index = loopDefinitions.firstIndex(where: { $0.id == definition.id || $0.filePath == definition.filePath }) {
            loopDefinitions[index] = current
        }
        return current
    }

    var selectedLoopDefinition: LoopDefinition? {
        guard let selectedLoopDefinitionID else { return nil }
        return loopDefinitions.first { $0.id == selectedLoopDefinitionID }
    }

    func requestNewLoopDefinition() {
        newLoopRequestID = UUID()
    }

    @discardableResult
    func saveLoopDefinition(_ definition: LoopDefinition) throws -> LoopDefinition {
        let saved = try loopDefinitionStore.saveUserDefinition(definition)
        reloadLoopDefinitions()
        selectedLoopDefinitionID = saved.filePath ?? saved.id
        return saved
    }

    @discardableResult
    func duplicateLoopDefinition(_ definition: LoopDefinition) throws -> LoopDefinition {
        let saved = try loopDefinitionStore.duplicateUserDefinition(definition)
        reloadLoopDefinitions()
        selectedLoopDefinitionID = saved.filePath ?? saved.id
        return saved
    }

    func deleteLoopDefinition(_ definition: LoopDefinition) throws {
        try loopDefinitionStore.deleteUserDefinition(definition)
        reloadLoopDefinitions()
    }

    @discardableResult
    func saveLoopDefinitionFromRun(_ run: LoopRun) throws -> LoopDefinition {
        try saveLoopDefinitionFromDraft(
            loopDraft(from: run),
            request: LoopSaveRequest(
                name: defaultLoopSaveName(for: run),
                description: "Saved from completed loop run.",
                availability: run.projectPath?.isEmpty == false ? .projectPaths : .allProjects,
                projectPaths: run.projectPath.map { [$0] } ?? []
            )
        )
    }

    func retryLoopRun(_ run: LoopRun) {
        guard !run.isActive, run.status == .failed || run.presentsGoalNotMetOutcome || run.stopReason == .humanInputRequired || run.stopReason == .humanApproved else { return }
        guard let session = piAgentSessionStore.sessions.first(where: { $0.id == run.sessionID }) else { return }
        let draft = loopDraft(from: run)
        Task { @MainActor in
            _ = await launchLoop(session: session, draft: draft, stopExistingActive: false)
        }
    }

    func loopDraft(from run: LoopRun) -> LoopDraft {
        LoopDraft(
            goal: run.goal,
            launchContext: run.launchContext,
            launchContextScope: run.launchContextScope,
            structure: run.structure,
            writeTarget: run.writeTarget,
            maxIterations: run.maxIterations,
            validationCommand: run.validationCommand,
            goalEvaluation: run.goalEvaluation,
            makerChecker: run.makerChecker,
            pipeline: run.pipeline,
            parallel: run.parallel,
            discoveryTriage: run.discoveryTriage,
            humanApproval: run.humanApproval
        )
    }

    func defaultLoopSaveName(for run: LoopRun) -> String {
        let firstLine = run.goal.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Saved Loop" : String(trimmed.prefix(64))
    }

    @discardableResult
    func saveLoopDefinitionFromDraft(_ draft: LoopDraft, request: LoopSaveRequest) throws -> LoopDefinition {
        let projectPaths = request.availability == .projectPaths ? request.projectPaths : []
        let definition = LoopDefinition(
            name: request.name,
            description: request.description,
            goalTemplate: draft.goal,
            launchContext: draft.launchContext,
            launchContextScope: draft.launchContextScope,
            structure: draft.structure,
            writeTarget: draft.writeTarget,
            maxIterations: draft.maxIterations,
            validationCommand: draft.validationCommand,
            goalEvaluation: draft.goalEvaluation,
            makerChecker: draft.makerChecker,
            pipeline: draft.pipeline,
            parallel: draft.parallel,
            discoveryTriage: draft.discoveryTriage,
            humanApproval: draft.humanApproval,
            source: .user,
            availability: request.availability,
            projectPaths: projectPaths
        )
        let saved = try loopDefinitionStore.saveUserDefinition(definition)
        reloadLoopDefinitions()
        return saved
    }

    func configureLoopDefinitionStoreForTesting(directoryURL: URL) {
        loopDefinitionStore = LoopDefinitionStore(directoryURL: directoryURL)
        reloadLoopDefinitions()
    }

}
