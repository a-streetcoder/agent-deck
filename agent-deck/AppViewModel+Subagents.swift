import AppKit
import Foundation

// MARK: - Native subagents & loops

extension AppViewModel {
    func runNativeSubagent(agentName: String, task: String, useWorktreeIsolation: Bool = false, allowDirectProjectWrites: Bool = false, expectedOutcome: PiSubagentExpectedOutcome = .reportOnly, requestedOutputPath: String? = nil, allowOverwrite: Bool = false, readFirstPaths: [String] = []) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        Task { @MainActor [weak self] in
            await self?.runNativeSubagent(parentSession: session, agentName: agentName, task: task, useWorktreeIsolation: useWorktreeIsolation, allowDirectProjectWrites: allowDirectProjectWrites, expectedOutcome: expectedOutcome, requestedOutputPath: requestedOutputPath, allowOverwrite: allowOverwrite, readFirstPaths: readFirstPaths, completion: nil)
        }
    }

    func runNativeParallel(agentTasks: [(agentName: String, task: String)], concurrency: Int = 4, useWorktreeIsolation: Bool = false) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        Task { @MainActor [weak self] in
            await self?.runNativeParallel(parentSession: session, agentTasks: agentTasks, concurrency: concurrency, useWorktreeIsolation: useWorktreeIsolation, completion: nil)
        }
    }

    func runManagedNativeSubagent(parentSessionID: UUID, request: PiManagedSubagentBridgeRequest, completion: @escaping (String) -> Void) async {
        guard let session = piAgentSessionStore.sessions.first(where: { $0.id == parentSessionID }) else {
            completion("\(AppBrand.displayName) could not find the parent session.")
            return
        }
        guard !session.isNoProject, session.projectPathForProjectFeatures != nil else {
            completion(LanguageStore.shared.t("vm.deckAgentsUnavailableGeneralChat"))
            return
        }
        guard session.subagentsEnabled else {
            completion("Deck agents are disabled for this \(AppBrand.displayName) session.")
            return
        }
        let continueRunID = request.continueSubagentID.flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if request.continueSubagentID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, continueRunID == nil {
            completion("Invalid continueSubagentID `\(request.continueSubagentID ?? "")`. Use the Deck agent ID shown on the Deck agent card.")
            return
        }
        let useWorktreeIsolation = false
        let agent = catalogAgents(for: session).first { $0.name == request.agent.trimmingCharacters(in: .whitespacesAndNewlines) }
        let expectedOutcome: PiSubagentExpectedOutcome = agent?.resolved.defaultExpectedOutcome ?? .reportOnly
        let allowDirectProjectWrites = expectedOutcome == .directProjectWrites
        let gate = NativeSubagentCompletionGate()
        var timeoutTask: Task<Void, Never>?
        let launchedRun = await runNativeSubagent(parentSession: session, agentName: request.agent, task: request.task, continueRunID: continueRunID, useWorktreeIsolation: useWorktreeIsolation, allowDirectProjectWrites: allowDirectProjectWrites, expectedOutcome: expectedOutcome, requestedOutputPath: nil, allowOverwrite: false, readFirstPaths: request.reads ?? []) { run in
            timeoutTask?.cancel()
            gate.complete {
                let status = run.status == .completed ? "completed" : run.status.rawValue
                let summary = run.summary ?? run.error ?? LanguageStore.shared.t("vm.noSummaryReturned")
                let isPersistedRun = self.piAgentSessionStore.subagentRuns(for: parentSessionID).contains { $0.id == run.id }
                let idLine = isPersistedRun ? "\nDeck agent ID: \(run.id.uuidString)" : ""
                completion("Deck agent \(run.agentName) \(status).\(idLine)\n\n\(summary)")
            }
        }
        if launchedRun.status.isActive, !gate.isCompleted {
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30 * 60))
                await MainActor.run {
                    guard let self else { return }
                    gate.complete {
                        self.nativeSubagentRunner.stop(runID: launchedRun.id, parentSessionID: parentSessionID)
                        completion("Deck agent \(launchedRun.agentName) timed out after 30 minutes waiting for a result.")
                    }
                }
            }
        }
    }

    func runManagedNativeParallel(parentSessionID: UUID, request: PiManagedParallelBridgeRequest, completion: @escaping (String) -> Void) async {
        guard let session = piAgentSessionStore.sessions.first(where: { $0.id == parentSessionID }) else {
            completion("\(AppBrand.displayName) could not find the parent session.")
            return
        }
        guard !session.isNoProject, session.projectPathForProjectFeatures != nil else {
            completion(LanguageStore.shared.t("vm.deckAgentsUnavailableGeneralChat"))
            return
        }
        guard session.subagentsEnabled else {
            completion("Deck agents are disabled for this \(AppBrand.displayName) session.")
            return
        }
        let tasks = request.tasks.map { (agentName: $0.agent, task: $0.task) }
        let useWorktreeIsolation = request.worktree == true
        await runNativeParallel(parentSession: session, agentTasks: tasks, concurrency: request.concurrency ?? 4, useWorktreeIsolation: useWorktreeIsolation) { run in
            let status = run.status == .completed ? "completed" : run.status.rawValue
            completion("Deck agent parallel run \(status).\n\n\(run.summary ?? run.error ?? LanguageStore.shared.t("vm.noSummaryReturned"))")
        }
    }

    @discardableResult
    func runNativeSubagent(parentSession: PiAgentSessionRecord, agentName: String, task: String, continueRunID: UUID? = nil, useWorktreeIsolation: Bool, allowDirectProjectWrites: Bool = false, expectedOutcome: PiSubagentExpectedOutcome = .reportOnly, requestedOutputPath: String? = nil, allowOverwrite: Bool = false, readFirstPaths: [String] = [], completion: ((PiSubagentRunRecord) -> Void)?) async -> PiSubagentRunRecord {
        guard piAgentSessionStore.sessions.contains(where: { $0.id == parentSession.id }) else {
            return PiSubagentRunRecord.failedPlaceholder(parentSessionID: parentSession.id, agentName: agentName, task: task, error: LanguageStore.shared.t("vm.parentSessionDeleted"))
        }
        guard !parentSession.isNoProject, let projectPath = parentSession.projectPathForProjectFeatures else {
            let message = LanguageStore.shared.t("vm.deckAgentsUnavailableLaunch")
            piAgentSessionStore.append(.init(sessionID: parentSession.id, role: .error, title: "Deck Agents Unavailable", text: message))
            let placeholder = PiSubagentRunRecord.failedPlaceholder(parentSessionID: parentSession.id, agentName: agentName, task: task, error: message)
            completion?(placeholder)
            return placeholder
        }
        guard parentSession.subagentsEnabled else {
            let message = "Deck agents are disabled for this session."
            piAgentSessionStore.append(.init(sessionID: parentSession.id, role: .error, title: "Deck Agents Disabled", text: message))
            let placeholder = PiSubagentRunRecord.failedPlaceholder(parentSessionID: parentSession.id, agentName: agentName, task: task, error: message)
            completion?(placeholder)
            return placeholder
        }
        let snapshot = startupSnapshot(forProjectPath: projectPath)
        guard let agent = catalogAgents(for: parentSession).first(where: { $0.name == agentName }) else {
            let message = LanguageStore.shared.t("vm.noEnabledAgentNamed", agentName)
            piAgentSessionStore.append(.init(sessionID: parentSession.id, role: .error, title: "Deck Agent Not Found", text: message))
            let placeholder = PiSubagentRunRecord.failedPlaceholder(parentSessionID: parentSession.id, agentName: agentName, task: task, error: message)
            completion?(placeholder)
            return placeholder
        }
        if let validationError = validateNativeSubagentOutcome(parentSession: parentSession, expectedOutcome: expectedOutcome, requestedOutputPath: requestedOutputPath, allowOverwrite: allowOverwrite, allowDirectProjectWrites: allowDirectProjectWrites) {
            piAgentSessionStore.append(.init(sessionID: parentSession.id, role: .error, title: "Deck Agent Output Policy", text: validationError))
            let placeholder = PiSubagentRunRecord.failedPlaceholder(parentSessionID: parentSession.id, agentName: agentName, task: task, error: validationError)
            completion?(placeholder)
            return placeholder
        }
        return await runNativeSubagent(parentSession: parentSession, agent: agent, snapshot: snapshotWithSkillCatalog(snapshot, projectPath: projectPath), task: task, continueRunID: continueRunID, useWorktreeIsolation: useWorktreeIsolation, expectedOutcome: expectedOutcome, requestedOutputPath: requestedOutputPath, allowOverwrite: allowOverwrite, readFirstPaths: readFirstPaths, completion: completion)
    }

    func snapshotWithSkillCatalog(_ base: ScanSnapshot, projectPath: String) -> ScanSnapshot {
        ScanSnapshot(
            projectRoot: base.projectRoot,
            builtinAgents: base.builtinAgents,
            globalAgents: base.globalAgents,
            projectAgents: base.projectAgents,
            legacyProjectAgents: base.legacyProjectAgents,
            effectiveAgents: base.effectiveAgents,
            libraryAgents: base.libraryAgents,
            skills: skillCatalog(forProjectPath: projectPath),
            librarySkills: [],
            promptTemplates: base.promptTemplates,
            libraryPromptTemplates: base.libraryPromptTemplates,
            settings: base.settings,
            envKeys: base.envKeys,
            warnings: base.warnings
        )
    }

    @discardableResult
    func launchLoop(session: PiAgentSessionRecord, draft: LoopDraft, stopExistingActive: Bool) async -> LoopRun? {
        guard session.projectPathForProjectFeatures != nil else {
            piAgentSessionStore.append(.init(sessionID: session.id, role: .error, title: LanguageStore.shared.t("vm.loopUnavailable"), text: LanguageStore.shared.t("vm.loopsUnavailableGeneralChat")))
            return nil
        }
        prepareSessionForLoopLaunch(session: session, draft: draft)
        switch draft.structure {
        case .singleAgent:
            return await launchSingleAgentLoop(session: session, draft: draft, stopExistingActive: stopExistingActive)
        case .agentPipeline:
            return await launchAgentPipelineLoop(session: session, draft: draft, stopExistingActive: stopExistingActive)
        case .makerChecker:
            return await launchMakerCheckerLoop(session: session, draft: draft, stopExistingActive: stopExistingActive)
        case .discoveryTriage:
            return await launchDiscoveryTriageLoop(session: session, draft: draft, stopExistingActive: stopExistingActive)
        case .parallelAgents:
            return await launchParallelAgentsLoop(session: session, draft: draft, stopExistingActive: stopExistingActive)
        case .humanApproval:
            guard let projectPath = session.projectPathForProjectFeatures else { return nil }
            return piAgentSessionStore.launchSmokeLoop(sessionID: session.id, projectPath: projectPath, draft: draft, stopExistingActive: stopExistingActive)
        }
    }

    func prepareSessionForLoopLaunch(session: PiAgentSessionRecord, draft: LoopDraft) {
        piAgentSessionStore.updateSession(session.id, bumpUpdatedAt: false) { record in
            // A loop uses its own configured child agents; the composer-time Deck
            // agent picker should not continue to advertise a draft-only launch
            // selection once the loop has started.
            record.agentSelection = nil
        }
        schedulePiAgentTitleGenerationIfNeeded(for: session, firstMessage: draft.goal)
    }

    func loopAgentsByName(session: PiAgentSessionRecord, snapshot: ScanSnapshot) -> [String: EffectiveAgentRecord]? {
        do {
            return try PiAgentLaunchResolver.agentsByName(snapshot.effectiveAgents)
        } catch let error as PiAgentLaunchResolver.DuplicateEffectiveAgentNamesError {
            let names = error.names.map { "\"\($0)\"" }.joined(separator: ", ")
            piAgentSessionStore.append(.init(
                sessionID: session.id,
                role: .error,
                title: "Loop Agent Resolution Failed",
                text: "Multiple effective agents resolved with the same name: \(names). Review this project's agent assignments and try again."
            ))
            return nil
        } catch {
            piAgentSessionStore.append(.init(
                sessionID: session.id,
                role: .error,
                title: "Loop Agent Resolution Failed",
                text: "The project's effective agents could not be resolved."
            ))
            return nil
        }
    }

    @discardableResult
    func launchSingleAgentLoop(session: PiAgentSessionRecord, draft: LoopDraft, stopExistingActive: Bool) async -> LoopRun? {
        guard let projectPath = session.projectPathForProjectFeatures else { return nil }
        let snapshot = startupSnapshot(forProjectPath: projectPath)
        guard let agentsByName = loopAgentsByName(session: session, snapshot: snapshot) else { return nil }
        return await piAgentSessionStore.launchSingleAgentLoop(session: session, draft: draft, stopExistingActive: stopExistingActive, executeEvaluator: loopGoalEvaluatorExecutor(session: session, snapshot: snapshot, draft: draft)) { [weak self] loopID, agentName, task, writeTarget, workingDirectory, requestedOutputPath in
            guard let self else { return nil }
            guard let agent = agentsByName[agentName], agent.resolved.disabled != true else {
                self.piAgentSessionStore.append(.init(sessionID: session.id, role: .error, title: "Loop Agent Unavailable", text: "Single-agent role \"\(agentName)\" is not available in this project."))
                return nil
            }
            var executionSession = session
            if writeTarget == .newWorktree, let workingDirectory { executionSession.worktreePath = workingDirectory.path }
            let expectedOutcome: PiSubagentExpectedOutcome = switch writeTarget {
            case .artifactMarkdown: .reportOnly
            case .newWorktree: .editFilesInWorktree
            case .currentCheckout: .directProjectWrites
            }
            return await self.runNativeSubagentAndWait(parentSession: executionSession, agent: agent, snapshot: snapshot, task: task, useWorktreeIsolation: false, expectedOutcome: expectedOutcome, requestedOutputPath: requestedOutputPath, loopID: loopID)
        }
    }

    @discardableResult
    func launchParallelAgentsLoop(session: PiAgentSessionRecord, draft: LoopDraft, stopExistingActive: Bool) async -> LoopRun? {
        guard let projectPath = session.projectPathForProjectFeatures else { return nil }
        let snapshot = startupSnapshot(forProjectPath: projectPath)
        guard let agentsByName = loopAgentsByName(session: session, snapshot: snapshot) else { return nil }
        let selectedNames = draft.parallel.branchNames
        guard !selectedNames.isEmpty, selectedNames.allSatisfy({ name in
            guard let agent = agentsByName[name] else { return false }
            return agent.resolved.disabled != true
        }) else {
            piAgentSessionStore.append(.init(sessionID: session.id, role: .error, title: "Loop Agent Unavailable", text: "Parallel loops require explicitly selected enabled agents."))
            return nil
        }
        guard draft.writeTarget == .artifactMarkdown else {
            piAgentSessionStore.append(.init(sessionID: session.id, role: .error, title: "Parallel Loop Write Target", text: "Parallel loops are report-only to avoid concurrent writes. Select Artifact / Markdown output."))
            return nil
        }
        return await piAgentSessionStore.launchParallelAgentsLoop(session: session, draft: draft, stopExistingActive: stopExistingActive, executeEvaluator: loopGoalEvaluatorExecutor(session: session, snapshot: snapshot, draft: draft)) { [weak self] loopID, tasks, concurrency, _ in
            guard let self else { return nil }
            return await withCheckedContinuation { continuation in
                Task { @MainActor in
                    await self.runNativeParallel(parentSession: session, agentTasks: tasks, concurrency: min(concurrency, 2), useWorktreeIsolation: false, forcedExpectedOutcome: .reportOnly, loopID: loopID) { run in
                        continuation.resume(returning: run)
                    }
                }
            }
        }
    }

    @discardableResult
    func launchDiscoveryTriageLoop(session: PiAgentSessionRecord, draft: LoopDraft, stopExistingActive: Bool) async -> LoopRun? {
        guard let projectPath = session.projectPathForProjectFeatures else { return nil }
        let snapshot = startupSnapshot(forProjectPath: projectPath)
        guard let agentsByName = loopAgentsByName(session: session, snapshot: snapshot) else { return nil }
        return await piAgentSessionStore.launchDiscoveryTriageLoop(session: session, draft: draft, stopExistingActive: stopExistingActive, executeEvaluator: loopGoalEvaluatorExecutor(session: session, snapshot: snapshot, draft: draft)) { [weak self] loopID, agentName, task, writeTarget, workingDirectory, requestedOutputPath in
            guard let self else { return nil }
            guard let agent = agentsByName[agentName], agent.resolved.disabled != true else {
                self.piAgentSessionStore.append(.init(sessionID: session.id, role: .error, title: "Loop Agent Unavailable", text: "Discovery/Triage agent \"\(agentName)\" is not available in this project."))
                return nil
            }
            var executionSession = session
            if writeTarget == .newWorktree, let workingDirectory { executionSession.worktreePath = workingDirectory.path }
            let expectedOutcome: PiSubagentExpectedOutcome = switch writeTarget {
            case .artifactMarkdown: .reportOnly
            case .newWorktree: .editFilesInWorktree
            case .currentCheckout: .directProjectWrites
            }
            return await self.runNativeSubagentAndWait(parentSession: executionSession, agent: agent, snapshot: snapshot, task: task, useWorktreeIsolation: false, expectedOutcome: expectedOutcome, requestedOutputPath: requestedOutputPath, loopID: loopID)
        }
    }

    @discardableResult
    func launchMakerCheckerLoop(session: PiAgentSessionRecord, draft: LoopDraft, stopExistingActive: Bool) async -> LoopRun? {
        guard let projectPath = session.projectPathForProjectFeatures else { return nil }
        let snapshot = startupSnapshot(forProjectPath: projectPath)
        guard let agentsByName = loopAgentsByName(session: session, snapshot: snapshot) else { return nil }
        return await piAgentSessionStore.launchMakerCheckerLoop(session: session, draft: draft, stopExistingActive: stopExistingActive, executeEvaluator: loopGoalEvaluatorExecutor(session: session, snapshot: snapshot, draft: draft)) { [weak self] loopID, roleName, task, writeTarget, workingDirectory, requestedOutputPath in
            guard let self else { return nil }
            guard let agent = agentsByName[roleName], agent.resolved.disabled != true else {
                self.piAgentSessionStore.append(.init(sessionID: session.id, role: .error, title: "Loop Agent Unavailable", text: "Maker/checker role \"\(roleName)\" is not available in this project."))
                return nil
            }
            var executionSession = session
            if writeTarget == .newWorktree, let workingDirectory { executionSession.worktreePath = workingDirectory.path }
            let expectedOutcome: PiSubagentExpectedOutcome = switch writeTarget {
            case .artifactMarkdown: .reportOnly
            case .newWorktree: .editFilesInWorktree
            case .currentCheckout: .directProjectWrites
            }
            return await self.runNativeSubagentAndWait(parentSession: executionSession, agent: agent, snapshot: snapshot, task: task, useWorktreeIsolation: false, expectedOutcome: expectedOutcome, requestedOutputPath: requestedOutputPath, loopID: loopID)
        }
    }

    @discardableResult
    func launchAgentPipelineLoop(session: PiAgentSessionRecord, draft: LoopDraft, stopExistingActive: Bool) async -> LoopRun? {
        guard let projectPath = session.projectPathForProjectFeatures else { return nil }
        let snapshot = startupSnapshot(forProjectPath: projectPath)
        guard let agentsByName = loopAgentsByName(session: session, snapshot: snapshot) else { return nil }
        return await piAgentSessionStore.launchAgentPipelineLoop(session: session, draft: draft, stopExistingActive: stopExistingActive, executeEvaluator: loopGoalEvaluatorExecutor(session: session, snapshot: snapshot, draft: draft)) { [weak self] loopID, stageName, task, writeTarget, workingDirectory, requestedOutputPath in
            guard let self else { return nil }
            guard let agent = agentsByName[stageName], agent.resolved.disabled != true else {
                self.piAgentSessionStore.append(.init(sessionID: session.id, role: .error, title: "Loop Agent Unavailable", text: "Pipeline stage \"\(stageName)\" is not available in this project."))
                return nil
            }
            var executionSession = session
            if writeTarget == .newWorktree, let workingDirectory {
                executionSession.worktreePath = workingDirectory.path
            }
            let expectedOutcome: PiSubagentExpectedOutcome
            switch writeTarget {
            case .artifactMarkdown:
                expectedOutcome = .reportOnly
            case .newWorktree:
                expectedOutcome = .editFilesInWorktree
            case .currentCheckout:
                expectedOutcome = .directProjectWrites
            }
            let childRun = await self.runNativeSubagentAndWait(
                parentSession: executionSession,
                agent: agent,
                snapshot: snapshot,
                task: task,
                useWorktreeIsolation: false,
                expectedOutcome: expectedOutcome,
                requestedOutputPath: requestedOutputPath,
                loopID: loopID
            )
            return childRun
        }
    }

    func loopGoalEvaluatorExecutor(session: PiAgentSessionRecord, snapshot: ScanSnapshot, draft: LoopDraft) -> PiAgentSessionStore.LoopChildExecutor {
        { [weak self] loopID, _, task, _, workingDirectory, requestedOutputPath in
            guard let self else { return nil }
            var executionSession = session
            if let workingDirectory, draft.writeTarget == .newWorktree { executionSession.worktreePath = workingDirectory.path }
            let agent = self.loopGoalEvaluatorAgent(config: draft.goalEvaluation)
            return await self.runNativeSubagentAndWait(parentSession: executionSession, agent: agent, snapshot: snapshot, task: task, useWorktreeIsolation: false, expectedOutcome: .reportOnly, requestedOutputPath: requestedOutputPath, loopID: loopID)
        }
    }

    func loopGoalEvaluatorAgent(config: LoopGoalEvaluationConfig) -> EffectiveAgentRecord {
        var resolved = AgentConfig.empty
        resolved.name = "Goal Evaluator"
        resolved.description = "Report-only natural-language loop goal evaluator."
        resolved.model = config.model
        resolved.thinking = config.thinkingLevel
        resolved.tools = []
        resolved.skills = []
        resolved.defaultExpectedOutcome = .reportOnly
        resolved.systemPrompt = "You are Agent Deck's report-only natural-language goal evaluator. You review evidence and answer only with SUCCESS, CONTINUE, or FAIL followed by a concise rationale. Do not edit files."
        return EffectiveAgentRecord(id: "agent-deck-loop-goal-evaluator", name: "Goal Evaluator", projectRoot: nil, builtin: nil, globalCustom: nil, projectCustom: nil, userOverride: nil, projectOverride: nil, resolved: resolved, resolutionKind: .builtin)
    }

    func runNativeSubagentAndWait(parentSession: PiAgentSessionRecord, agent: EffectiveAgentRecord, snapshot: ScanSnapshot, task: String, useWorktreeIsolation: Bool, expectedOutcome: PiSubagentExpectedOutcome, requestedOutputPath: String?, loopID: UUID) async -> PiSubagentRunRecord {
        await withCheckedContinuation { continuation in
            var didResume = false
            Task { @MainActor in
                let launched = await runNativeSubagent(
                    parentSession: parentSession,
                    agent: agent,
                    snapshot: snapshot,
                    task: task,
                    useWorktreeIsolation: useWorktreeIsolation,
                    expectedOutcome: expectedOutcome,
                    requestedOutputPath: requestedOutputPath,
                    allowOverwrite: true,
                    completion: { completed in
                        if self.activePipelineChildRunByLoopID[loopID] == completed.id {
                            self.activePipelineChildRunByLoopID[loopID] = nil
                        }
                        guard !didResume else { return }
                        didResume = true
                        continuation.resume(returning: completed)
                    }
                )
                self.activePipelineChildRunByLoopID[loopID] = launched.id
                if !launched.status.isActive {
                    self.activePipelineChildRunByLoopID[loopID] = nil
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: launched)
                }
            }
        }
    }

    @discardableResult
    func runNativeSubagent(parentSession: PiAgentSessionRecord, agent: EffectiveAgentRecord, snapshot: ScanSnapshot, task: String, continueRunID: UUID? = nil, useWorktreeIsolation: Bool, expectedOutcome: PiSubagentExpectedOutcome = .reportOnly, requestedOutputPath: String? = nil, allowOverwrite: Bool = false, readFirstPaths: [String] = [], completion: ((PiSubagentRunRecord) -> Void)?) async -> PiSubagentRunRecord {
        guard !parentSession.isNoProject, parentSession.projectPathForProjectFeatures != nil else {
            let message = LanguageStore.shared.t("vm.deckAgentsUnavailableLaunch")
            piAgentSessionStore.append(.init(sessionID: parentSession.id, role: .error, title: "Deck Agents Unavailable", text: message))
            let placeholder = PiSubagentRunRecord.failedPlaceholder(parentSessionID: parentSession.id, agentName: agent.name, task: task, error: message)
            completion?(placeholder)
            return placeholder
        }
        do {
            return try await nativeSubagentRunner.runSingle(parentSession: parentSession, agent: agent, snapshot: snapshot, task: task, continueRunID: continueRunID, useWorktreeIsolation: useWorktreeIsolation, expectedOutcome: expectedOutcome, requestedOutputPath: requestedOutputPath, allowOverwrite: allowOverwrite, readFirstPaths: readFirstPaths, onCompletion: completion)
        } catch {
            piAgentSessionStore.append(.init(sessionID: parentSession.id, role: .error, title: "Deck Agent Launch Failed", text: error.localizedDescription))
            let placeholder = PiSubagentRunRecord.failedPlaceholder(parentSessionID: parentSession.id, agentName: agent.name, task: task, error: error.localizedDescription)
            completion?(placeholder)
            return placeholder
        }
    }

    func runNativeParallel(parentSession: PiAgentSessionRecord, agentTasks: [(agentName: String, task: String)], concurrency: Int, useWorktreeIsolation: Bool, forcedExpectedOutcome: PiSubagentExpectedOutcome? = nil, loopID: UUID? = nil, completion: ((PiSubagentRunRecord) -> Void)?) async {
        guard !parentSession.isNoProject, parentSession.projectPathForProjectFeatures != nil else {
            let message = LanguageStore.shared.t("vm.deckAgentsUnavailableLaunch")
            piAgentSessionStore.append(.init(sessionID: parentSession.id, role: .error, title: "Deck Agents Unavailable", text: message))
            completion?(PiSubagentRunRecord.failedPlaceholder(parentSessionID: parentSession.id, agentName: "Parallel", task: "Parallel Deck agent task(s)", error: message))
            return
        }
        let tasks = agentTasks.map { ($0.agentName.trimmingCharacters(in: .whitespacesAndNewlines), $0.task.trimmingCharacters(in: .whitespacesAndNewlines)) }.filter { !$0.0.isEmpty && !$0.1.isEmpty }
        guard !tasks.isEmpty else { return }
        let now = Date()
        let runID = UUID()
        let artifactDirectory = nativeGraphArtifactDirectory(for: runID)
        let defaultOutcomeByAgent = nativeSubagentDefaultOutcomes(parentSession: parentSession, agentNames: tasks.map(\.0))
        let childRecords = tasks.enumerated().map { index, item in
            let expectedOutcome = forcedExpectedOutcome ?? (useWorktreeIsolation ? PiSubagentExpectedOutcome.editFilesInWorktree : (defaultOutcomeByAgent[item.0] ?? .reportOnly))
            return PiSubagentChildRecord(
                id: UUID(), runID: runID, index: index, agentName: item.0, task: item.1,
                status: .queued, model: nil, thinking: nil,
                expectedOutcome: expectedOutcome, requestedOutputPath: nil, allowOverwrite: false,
                currentTool: nil, inputTokens: nil, outputTokens: nil, totalTokens: nil, toolCount: nil, durationMs: nil,
                artifactDirectory: nil, sessionFile: nil, outputPath: nil, worktreePath: nil, launchCommand: nil, executionRunID: nil,
                summary: nil, error: nil, dependencies: nil, injectedMemoryIDs: nil, injectedMemoryTitles: nil, completedAt: nil, createdAt: now, updatedAt: now
            )
        }
        let limit = max(1, min(concurrency, tasks.count))
        let run = nativeGraphRun(id: runID, parentSession: parentSession, mode: .parallel, title: "Parallel", task: "\(tasks.count) parallel Deck agent task(s)", artifactDirectory: artifactDirectory, children: childRecords, edges: [], concurrency: limit, worktreeIsolation: useWorktreeIsolation)
        piAgentSessionStore.upsertSubagentRun(run)
        if let loopID { activePipelineChildRunByLoopID[loopID] = runID }
        piAgentSessionStore.append(.init(
            sessionID: parentSession.id,
            role: .status,
            title: "Parallel Deck Agents Started",
            text: "Deck agent ID: \(run.id.uuidString)\n\nStarted \(tasks.count) task(s), concurrency \(limit).",
            rawJSON: nativeSubagentCardPayload(for: run)
        ))
        let scheduler = NativeParallelGraphScheduler(parentSession: parentSession, graphRunID: runID, tasks: tasks.map { (agentName: $0.0, task: $0.1) }, concurrency: limit, useWorktreeIsolation: useWorktreeIsolation, forcedExpectedOutcome: forcedExpectedOutcome) { [weak self] completed in
            if let loopID, self?.activePipelineChildRunByLoopID[loopID] == completed.id {
                self?.activePipelineChildRunByLoopID[loopID] = nil
            }
            completion?(completed)
        }
        nativeParallelSchedulersByID[scheduler.id] = scheduler
        await pumpNativeParallelScheduler(scheduler)
    }

    func pumpNativeParallelScheduler(_ scheduler: NativeParallelGraphScheduler) async {
        guard !scheduler.isCancelled,
              piAgentSessionStore.sessions.contains(where: { $0.id == scheduler.parentSession.id }) else { return }
        if scheduler.completed == scheduler.tasks.count {
            let run = piAgentSessionStore.subagentRuns(for: scheduler.parentSession.id).first(where: { $0.id == scheduler.graphRunID })
            // children is insertion-sorted by index (invariant documented on PiSubagentRunRecord).
            let summaries = (run?.children ?? []).map { "- \($0.agentName): \($0.summary ?? $0.error ?? $0.status.rawValue)" }.joined(separator: "\n")
            finishNativeGraphRun(scheduler.graphRunID, parentSessionID: scheduler.parentSession.id, status: scheduler.failed ? .failed : .completed, summary: summaries, completion: scheduler.completion)
            nativeParallelSchedulersByID[scheduler.id] = nil
            return
        }
        while !scheduler.isCancelled,
              piAgentSessionStore.sessions.contains(where: { $0.id == scheduler.parentSession.id }),
              scheduler.active < scheduler.concurrency && scheduler.nextIndex < scheduler.tasks.count {
            let index = scheduler.nextIndex
            scheduler.nextIndex += 1
            scheduler.active += 1
            let item = scheduler.tasks[index]
            let expectedOutcome = scheduler.forcedExpectedOutcome ?? (scheduler.useWorktreeIsolation ? PiSubagentExpectedOutcome.editFilesInWorktree : nativeSubagentDefaultOutcome(parentSession: scheduler.parentSession, agentName: item.agentName))
            let allowDirectProjectWrites = expectedOutcome == .directProjectWrites
            updateNativeGraphChild(scheduler.graphRunID, parentSessionID: scheduler.parentSession.id, index: index) { $0.status = .running }
            let childRun = await runNativeSubagent(parentSession: scheduler.parentSession, agentName: item.agentName, task: item.task, useWorktreeIsolation: scheduler.useWorktreeIsolation, allowDirectProjectWrites: allowDirectProjectWrites, expectedOutcome: expectedOutcome) { [weak self, weak scheduler] childResult in
                guard let self, let scheduler, !scheduler.isCancelled else { return }
                self.updateNativeGraphChildFromRun(scheduler.graphRunID, parentSessionID: scheduler.parentSession.id, index: index, childResult: childResult)
                scheduler.active = max(0, scheduler.active - 1)
                scheduler.completed += 1
                scheduler.failed = scheduler.failed || childResult.status != .completed
                Task { @MainActor [weak self, weak scheduler] in
                    guard let self, let scheduler else { return }
                    await self.pumpNativeParallelScheduler(scheduler)
                }
            }
            guard !scheduler.isCancelled else { return }
            updateNativeGraphChildFromRun(scheduler.graphRunID, parentSessionID: scheduler.parentSession.id, index: index, childResult: childRun)
        }
    }

    func nativeSubagentDefaultOutcome(parentSession: PiAgentSessionRecord, agentName: String) -> PiSubagentExpectedOutcome {
        nativeSubagentDefaultOutcomes(parentSession: parentSession, agentNames: [agentName])[agentName] ?? .reportOnly
    }

    func nativeSubagentDefaultOutcomes(parentSession: PiAgentSessionRecord, agentNames: [String]) -> [String: PiSubagentExpectedOutcome] {
        let requestedNames = Set(agentNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !requestedNames.isEmpty else { return [:] }
        return Dictionary(uniqueKeysWithValues: catalogAgents(for: parentSession).compactMap { agent in
            guard requestedNames.contains(agent.name), let outcome = agent.resolved.defaultExpectedOutcome else { return nil }
            return (agent.name, outcome)
        })
    }

    func validateNativeSubagentOutcome(parentSession: PiAgentSessionRecord, expectedOutcome: PiSubagentExpectedOutcome, requestedOutputPath: String?, allowOverwrite: Bool, allowDirectProjectWrites: Bool) -> String? {
        switch expectedOutcome {
        case .reportOnly, .editFilesInWorktree:
            return nil
        case .directProjectWrites:
            return allowDirectProjectWrites ? nil : "Direct project writes require explicit approval."
        case .writeProjectFile:
            let trimmedPath = requestedOutputPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedPath.isEmpty else { return "Write/update project file requires a project-relative output path." }
            guard !trimmedPath.hasPrefix("/") && !trimmedPath.contains("..") else { return "Output path must be project-relative and cannot contain `..`." }
            guard let projectPath = parentSession.projectPathForProjectFeatures else { return "Write/update project file requires a project-backed session." }
            let rootURL = URL(fileURLWithPath: parentSession.worktreePath ?? projectPath)
            let outputURL = rootURL.appendingPathComponent(trimmedPath).standardizedFileURL
            let rootPath = rootURL.standardizedFileURL.path.hasSuffix("/") ? rootURL.standardizedFileURL.path : rootURL.standardizedFileURL.path + "/"
            guard (outputURL.path + (outputURL.hasDirectoryPath ? "/" : "")).hasPrefix(rootPath) else { return "Output path must stay inside the project." }
            if FileManager.default.fileExists(atPath: outputURL.path), !allowOverwrite {
                return "`\(trimmedPath)` already exists. Enable overwrite or choose another output path."
            }
            return nil
        }
    }

    func nativeGraphRun(id: UUID, parentSession: PiAgentSessionRecord, mode: PiSubagentRunMode, title: String, task: String, artifactDirectory: URL, children: [PiSubagentChildRecord], edges: [PiSubagentGraphEdgeRecord], concurrency: Int, worktreeIsolation: Bool) -> PiSubagentRunRecord {
        PiSubagentRunRecord(
            id: id, parentSessionID: parentSession.id, mode: mode, status: .running,
            agentName: title, task: task,
            model: nil, thinking: nil, expectedOutcome: worktreeIsolation ? .editFilesInWorktree : .reportOnly, requestedOutputPath: nil, allowOverwrite: false, tools: [], skills: [],
            concurrencyLimit: concurrency, worktreePolicy: worktreeIsolation ? "isolated-per-child" : "parent", aggregateSummary: nil,
            artifactDirectory: artifactDirectory.path, outputPath: artifactDirectory.appendingPathComponent("summary.md").path,
            worktreePath: nil, parentRepoPath: parentSession.worktreePath ?? parentSession.projectPathForProjectFeatures, baseCommit: nil,
            isWorktreeIsolated: false, worktreeStatus: PiSubagentWorktreeStatus.none, worktreePatchPath: nil,
            childSessionID: nil, childPiSessionFile: nil, launchCommand: nil, summary: nil, error: nil,
            child: nil, children: children, graphEdges: edges, injectedMemoryIDs: nil, injectedMemoryTitles: nil, createdAt: Date(), updatedAt: Date(), completedAt: nil, durationMs: nil
        )
    }

    func finishNativeGraphRun(_ runID: UUID, parentSessionID: UUID, status: PiSubagentRunStatus, summary: String, completion: ((PiSubagentRunRecord) -> Void)?) {
        let completedAt = Date()
        piAgentSessionStore.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
            run.status = status
            run.summary = summary
            run.aggregateSummary = summary
            run.completedAt = completedAt
            run.durationMs = max(0, Int((completedAt.timeIntervalSince(run.createdAt) * 1000).rounded()))
            if status == .failed { run.error = summary }
        }
        if let outputPath = piAgentSessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID })?.outputPath {
            try? summary.write(toFile: outputPath, atomically: true, encoding: .utf8)
        }
        piAgentSessionStore.append(.init(sessionID: parentSessionID, role: status == .completed ? .status : .error, title: status == .completed ? "Deck Agent Graph Completed" : "Deck Agent Graph Failed", text: summary))
        if let run = piAgentSessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }) { completion?(run) }
    }

    func updateNativeGraphChild(_ runID: UUID, parentSessionID: UUID, index: Int, mutate: (inout PiSubagentChildRecord) -> Void) {
        piAgentSessionStore.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
            guard var children = run.children, children.indices.contains(index) else { return }
            mutate(&children[index])
            children[index].updatedAt = Date()
            run.children = children
        }
    }

    func updateNativeGraphChildFromRun(_ graphRunID: UUID, parentSessionID: UUID, index: Int, childResult: PiSubagentRunRecord) {
        updateNativeGraphChild(graphRunID, parentSessionID: parentSessionID, index: index) { child in
            child.status = childResult.status
            child.executionRunID = childResult.id
            child.model = childResult.model ?? childResult.child?.model
            child.thinking = childResult.thinking ?? childResult.child?.thinking
            child.artifactDirectory = childResult.artifactDirectory
            child.outputPath = childResult.outputPath
            child.worktreePath = childResult.worktreePath
            child.launchCommand = childResult.launchCommand
            child.summary = childResult.summary
            child.error = childResult.error
            child.completedAt = childResult.completedAt
            child.durationMs = childResult.durationMs
            child.injectedMemoryIDs = childResult.injectedMemoryIDs ?? childResult.child?.injectedMemoryIDs
            child.injectedMemoryTitles = childResult.injectedMemoryTitles ?? childResult.child?.injectedMemoryTitles
        }
    }

    func recomputeNativeGraphCompletion(_ graphRunID: UUID, parentSessionID: UUID) {
        guard let run = piAgentSessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == graphRunID }), let children = run.children else { return }
        guard !children.contains(where: { $0.status.isActive || $0.status == .queued }) else { return }
        let summary = children.map { "- \($0.agentName): \($0.summary ?? $0.error ?? $0.status.rawValue)" }.joined(separator: "\n")
        finishNativeGraphRun(graphRunID, parentSessionID: parentSessionID, status: children.allSatisfy { $0.status == .completed } ? .completed : .failed, summary: summary, completion: nil)
    }

    func nativeSubagentCardPayload(for run: PiSubagentRunRecord) -> String? {
        let artifactDirectory = run.artifactDirectory
        let payload: [String: Any] = [
            "type": "agent_deck_subagent_card",
            "runID": run.id.uuidString,
            "agent": run.agentName,
            "artifactDirectory": artifactDirectory,
            "turnIndex": run.child?.index ?? 0,
            "authoredSystemPromptPath": URL(fileURLWithPath: artifactDirectory).appendingPathComponent("system-prompt.md").path,
            "finalSystemPromptPath": URL(fileURLWithPath: artifactDirectory).appendingPathComponent("final-system-prompt.md").path
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    func nativeGraphArtifactDirectory(for runID: UUID) -> URL {
        let appSupport = URL.applicationSupportDirectory
        let directory = appSupport.appendingPathComponent("\(AppBrand.displayName)", isDirectory: true).appendingPathComponent("Subagent Runs", isDirectory: true).appendingPathComponent(runID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func pendingSupervisorRequestsJSON(parentSessionID: UUID) -> String {
        let rows = piAgentSessionStore.supervisorRequests(for: parentSessionID)
            .filter { $0.status == .pending }
            .map { request -> [String: String] in
                [
                    "requestID": request.id,
                    "kind": request.kind.rawValue,
                    "title": request.title,
                    "message": request.message,
                    "runID": request.runID.uuidString
                ]
            }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    func answerSupervisorRequestFromParentAgent(parentSessionID: UUID, requestID: String, response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Supervisor response is empty." }
        guard piAgentSessionStore.supervisorRequests(for: parentSessionID).contains(where: { $0.id == requestID && $0.status == .pending }) else {
            return "No pending supervisor request found for id `\(requestID)`."
        }
        nativeSubagentRunner.respondToSupervisorRequest(requestID, parentSessionID: parentSessionID, response: trimmed)
        return "Supervisor response sent to child request `\(requestID)`."
    }

    func setSessionPlanFromParentAgent(sessionID: UUID, request: PiSessionPlanSetBridgeRequest) -> String {
        let plan = piAgentSessionStore.setSessionPlan(sessionID: sessionID, items: request.items)
        schedulePiAgentTitleUpdateIfNeeded(sessionID: sessionID, plan: plan)
        let rows = plan.items.map { ["id": $0.id, "title": $0.title, "status": $0.status.rawValue] }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "Session plan set with \(plan.items.count) item(s)."
        }
        return "Session plan set (`\(plan.id.uuidString)`). Use these item ids for updates:\n\(text)"
    }

    func updateSessionPlanFromParentAgent(sessionID: UUID, request: PiSessionPlanUpdateBridgeRequest) -> String {
        guard let plan = piAgentSessionStore.updateSessionPlan(sessionID: sessionID, updates: request.updates) else {
            return "No current session plan exists. Call set_session_plan first."
        }
        let rows = plan.items.map { ["id": $0.id, "title": $0.title, "status": $0.status.rawValue] }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "Session plan updated."
        }
        return "Session plan updated (`\(plan.id.uuidString)`):\n\(text)"
    }


    func nativeSubagentCatalogPrompt(for session: PiAgentSessionRecord) -> String? {
        let agents = catalogAgents(for: session)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !agents.isEmpty else { return nil }
        let lines = agents.map { agent in
            let routing = (agent.resolved.whenToUse ?? agent.resolved.description).trimmingCharacters(in: .whitespacesAndNewlines)
            let tools = (agent.resolved.tools ?? []).isEmpty ? "default tools" : "tools: \((agent.resolved.tools ?? []).joined(separator: ", "))"
            let outcome = agent.resolved.defaultExpectedOutcome?.displayName ?? "Report only"
            return "- \(agent.name): \(routing.isEmpty ? "Use when this specialist fits the requested task." : routing) [default outcome: \(outcome); \(tools)]"
        }
        let continuableRuns = piAgentSessionStore.subagentRuns(for: session.id)
            .filter { $0.mode == .single && !$0.status.isActive && $0.childPiSessionFile?.isEmpty == false }
            .prefix(6)
            .map { run in
                "- \(run.id.uuidString) \(run.agentName) — \(run.status.rawValue) — latest task: \(String(run.task.prefix(120)))"
            }
        let continuableSection = continuableRuns.isEmpty ? "" : "\n\nRecent continuable Deck agents:\n\(continuableRuns.joined(separator: "\n"))"
        return """
        \(AppBrand.displayName) orchestration (parent session):
        - App tools: `ask_user`, `set_session_plan`, `update_session_plan`, `managed_subagent`, `managed_parallel`, `list_supervisor_requests`, `answer_supervisor_request`.
        - Deck agents are separate child Pi sessions that \(AppBrand.displayName) launches and supervises. The only way to delegate to one is the `managed_subagent` or `managed_parallel` tool — they are not Pi slash commands, model-internal delegation, or hidden reasoning. If you do not call those tools, no delegation happens.
        \(appSettings.nativeSubagentDelegationPolicy.promptInstructions)
        - Use `ask_user` for one focused user decision when requirements are ambiguous or preference-dependent.
        - For multi-step work, keep a short parent-owned visible plan with `set_session_plan` and `update_session_plan`.
        - If you delegate planning to `planner`, convert its returned implementation plan into `set_session_plan` before implementation unless the user only asked for a report. Planner text alone does not update the visible \(AppBrand.displayName) plan.
        - Update the visible plan when steps start, complete, block, skip, or materially change.
        - Fresh Deck agents cannot see this parent conversation, its context window, reasoning, tool results, user decisions, or findings from prior agents. Do not assume a later `managed_subagent` call remembers an earlier child run.
        - Every fresh delegation must be self-contained in its task: state the goal, relevant requirements/decisions, constraints/findings, expected output, and useful current file reads (use `reads` when known).
        - The tool result and Deck agent card show a stable Deck agent ID. For a direct follow-up to a previous child, pass that ID as `continueSubagentID`; it restores only that child's own session, never parent context, and updates the same card.
        - If starting fresh for follow-up work, pass a compact continuity packet: prior findings/status, what changed, relevant files/artifact paths, and exact expected output.
        - Prefer fresh runs for independent work; prefer continuation for direct refinement, re-review, debugging, or answering a child-specific follow-up.

        Available Deck agents:
        \(lines.joined(separator: "\n"))\(continuableSection)
        """
    }

    func stopNativeSubagent(runID: UUID, parentSessionID: UUID) {
        if let run = piAgentSessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }), run.children?.isEmpty == false {
            stopNativeSubagentGraph(runID: runID, parentSessionID: parentSessionID)
            return
        }
        nativeSubagentRunner.stop(runID: runID, parentSessionID: parentSessionID)
    }

    func stopNativeSubagentGraph(runID: UUID, parentSessionID: UUID) {
        guard let run = piAgentSessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }) else { return }
        for child in run.children ?? [] where child.status.isActive {
            if let executionRunID = child.executionRunID {
                nativeSubagentRunner.stop(runID: executionRunID, parentSessionID: parentSessionID)
            }
        }
        let completedAt = Date()
        piAgentSessionStore.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
            run.status = .stopped
            run.completedAt = completedAt
            run.durationMs = max(0, Int((completedAt.timeIntervalSince(run.createdAt) * 1000).rounded()))
            if var children = run.children {
                for index in children.indices where children[index].status.isActive || children[index].status == .queued {
                    children[index].status = .stopped
                    children[index].updatedAt = completedAt
                    children[index].completedAt = completedAt
                    children[index].durationMs = max(0, Int((completedAt.timeIntervalSince(children[index].createdAt) * 1000).rounded()))
                }
                run.children = children
            }
        }
        piAgentSessionStore.append(.init(sessionID: parentSessionID, role: .status, title: "Deck Agent Graph Stopped", text: "Stopped graph run \(runID.uuidString)."))
    }

    func stopNativeSubagentGraphChild(graphRunID: UUID, childID: UUID, parentSessionID: UUID) {
        guard let run = piAgentSessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == graphRunID }),
              let child = (run.children ?? []).first(where: { $0.id == childID }) else { return }
        if let executionRunID = child.executionRunID, child.status.isActive {
            nativeSubagentRunner.stop(runID: executionRunID, parentSessionID: parentSessionID)
        }
        let completedAt = Date()
        piAgentSessionStore.updateSubagentRun(graphRunID, parentSessionID: parentSessionID) { run in
            guard var children = run.children, let index = children.firstIndex(where: { $0.id == childID }) else { return }
            children[index].status = .stopped
            children[index].updatedAt = completedAt
            children[index].completedAt = completedAt
            children[index].durationMs = max(0, Int((completedAt.timeIntervalSince(children[index].createdAt) * 1000).rounded()))
            run.children = children
        }
        piAgentSessionStore.append(.init(sessionID: parentSessionID, role: .status, title: "Deck Agent Child Stopped", text: "Stopped \(child.agentName)."))
    }

    func retryNativeSubagentGraphChild(graphRunID: UUID, childID: UUID, parentSessionID: UUID) {
        guard let parentSession = piAgentSessionStore.sessions.first(where: { $0.id == parentSessionID }),
              let run = piAgentSessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == graphRunID }),
              let children = run.children,
              let childIndex = children.firstIndex(where: { $0.id == childID }) else { return }
        piAgentSessionStore.updateSubagentRun(graphRunID, parentSessionID: parentSessionID) { run in
            run.status = .running
            run.error = nil
            guard var children = run.children else { return }
            children[childIndex].status = .running
            children[childIndex].summary = nil
            children[childIndex].error = nil
            children[childIndex].completedAt = nil
            children[childIndex].durationMs = nil
            children[childIndex].executionRunID = nil
            run.children = children
        }
        let child = children[childIndex]
        let isolated = run.worktreePolicy == "isolated-per-child"
        Task { @MainActor [weak self] in
            guard let self else { return }
            let childRun = await self.runNativeSubagent(parentSession: parentSession, agentName: child.agentName, task: child.task ?? run.task, useWorktreeIsolation: isolated, expectedOutcome: isolated ? .editFilesInWorktree : (child.expectedOutcome ?? .reportOnly), requestedOutputPath: child.requestedOutputPath, allowOverwrite: child.allowOverwrite == true) { [weak self] childResult in
                guard let self else { return }
                self.updateNativeGraphChildFromRun(graphRunID, parentSessionID: parentSessionID, index: childIndex, childResult: childResult)
                self.recomputeNativeGraphCompletion(graphRunID, parentSessionID: parentSessionID)
            }
            self.updateNativeGraphChildFromRun(graphRunID, parentSessionID: parentSessionID, index: childIndex, childResult: childRun)
        }
    }

    func openNativeSubagentWorktreePatch(runID: UUID, parentSessionID: UUID) {
        guard let run = piAgentSessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let patch = try await subagentWorktreeService.preparePatch(for: run)
                await MainActor.run {
                    piAgentSessionStore.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
                        run.worktreeStatus = .patchReady
                        run.worktreePatchPath = patch.patchPath
                    }
                    piAgentSessionStore.append(.init(sessionID: parentSessionID, role: .status, title: "Deck Agent Worktree Patch Ready", text: "\(patch.changedFiles.count) changed file(s).\n\n\(patch.patchPath)"))
                    NSWorkspace.shared.open(URL(fileURLWithPath: patch.patchPath))
                }
            } catch {
                await MainActor.run { recordSubagentWorktreeError(error, runID: runID, parentSessionID: parentSessionID) }
            }
        }
    }

    func applyNativeSubagentWorktreePatch(runID: UUID, parentSessionID: UUID) {
        guard let run = piAgentSessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let patch = try await subagentWorktreeService.applyPatch(for: run)
                await MainActor.run {
                    piAgentSessionStore.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
                        run.worktreeStatus = .applied
                        run.worktreePatchPath = patch.patchPath
                    }
                    piAgentSessionStore.append(.init(sessionID: parentSessionID, role: .status, title: "Deck Agent Worktree Applied", text: "Applied \(patch.changedFiles.count) changed file(s) from the isolated worktree.\n\nPatch: \(patch.patchPath)"))
                }
            } catch {
                await MainActor.run { recordSubagentWorktreeError(error, runID: runID, parentSessionID: parentSessionID) }
            }
        }
    }

    func discardNativeSubagentWorktree(runID: UUID, parentSessionID: UUID) {
        if let run = piAgentSessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }), run.status.isActive {
            nativeSubagentRunner.stop(runID: runID, parentSessionID: parentSessionID)
        }
        guard let run = piAgentSessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await subagentWorktreeService.discardWorktree(for: run)
                await MainActor.run {
                    piAgentSessionStore.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
                        run.worktreeStatus = .discarded
                    }
                    piAgentSessionStore.append(.init(sessionID: parentSessionID, role: .status, title: LanguageStore.shared.t("vm.deckAgentWorktreeDiscarded"), text: LanguageStore.shared.t("vm.removedIsolatedWorktree", runID.uuidString)))
                }
            } catch {
                await MainActor.run { recordSubagentWorktreeError(error, runID: runID, parentSessionID: parentSessionID) }
            }
        }
    }

    func applyLoopWorktree(_ loopRun: LoopRun) {
        guard let syntheticRun = loopWorktreeSubagentRecord(for: loopRun) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let patch = try await subagentWorktreeService.applyPatch(for: syntheticRun)
                try? "Applied at \(Date().formatted(date: .numeric, time: .standard))\nPatch: \(patch.patchPath)\n".write(to: URL(fileURLWithPath: syntheticRun.artifactDirectory).appendingPathComponent("worktree.applied"), atomically: true, encoding: .utf8)
                await MainActor.run {
                    piAgentSessionStore.markLoopWorktreeState(runID: loopRun.id, sessionID: loopRun.sessionID, state: .applied)
                    piAgentSessionStore.append(.init(sessionID: loopRun.sessionID, role: .status, title: "Loop Worktree Applied", text: "Applied \(patch.changedFiles.count) changed file(s) from the loop worktree.\n\nPatch: \(patch.patchPath)"))
                }
            } catch {
                await MainActor.run { piAgentSessionStore.append(.init(sessionID: loopRun.sessionID, role: .error, title: "Loop Worktree Apply Failed", text: error.localizedDescription)) }
            }
        }
    }

    func discardLoopWorktree(_ loopRun: LoopRun) {
        guard let syntheticRun = loopWorktreeSubagentRecord(for: loopRun) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await subagentWorktreeService.discardWorktree(for: syntheticRun)
                try? "Discarded at \(Date().formatted(date: .numeric, time: .standard))\n".write(to: URL(fileURLWithPath: syntheticRun.artifactDirectory).appendingPathComponent("worktree.discarded"), atomically: true, encoding: .utf8)
                await MainActor.run {
                    piAgentSessionStore.markLoopWorktreeState(runID: loopRun.id, sessionID: loopRun.sessionID, state: .discarded)
                    piAgentSessionStore.append(.init(sessionID: loopRun.sessionID, role: .status, title: LanguageStore.shared.t("vm.loopWorktreeDiscarded"), text: LanguageStore.shared.t("vm.removedLoopWorktree", loopRun.id.uuidString)))
                }
            } catch {
                await MainActor.run { piAgentSessionStore.append(.init(sessionID: loopRun.sessionID, role: .error, title: "Loop Worktree Discard Failed", text: error.localizedDescription)) }
            }
        }
    }

    func loopWorktreeSubagentRecord(for loopRun: LoopRun) -> PiSubagentRunRecord? {
        guard loopRun.writeTarget == .newWorktree, let artifactDirectoryPath = loopRun.artifactDirectoryPath else { return nil }
        let artifactURL = URL(fileURLWithPath: artifactDirectoryPath).standardizedFileURL
        let worktreePath = artifactURL.appendingPathComponent("worktree", isDirectory: true).path
        let now = Date()
        return PiSubagentRunRecord(
            id: loopRun.id,
            parentSessionID: loopRun.sessionID,
            mode: .single,
            status: loopRun.status == .completed ? .completed : .stopped,
            agentName: "Loop Worktree",
            task: loopRun.goal,
            model: nil,
            thinking: nil,
            expectedOutcome: .editFilesInWorktree,
            requestedOutputPath: nil,
            allowOverwrite: nil,
            readFirstPaths: nil,
            tools: [],
            skills: [],
            concurrencyLimit: nil,
            worktreePolicy: "loop-new-worktree",
            aggregateSummary: nil,
            artifactDirectory: artifactURL.path,
            outputPath: nil,
            worktreePath: worktreePath,
            parentRepoPath: loopRun.projectPath,
            baseCommit: nil,
            isWorktreeIsolated: true,
            worktreeStatus: nil,
            worktreePatchPath: nil,
            childSessionID: nil,
            childPiSessionFile: nil,
            launchCommand: nil,
            summary: nil,
            error: nil,
            child: nil,
            children: nil,
            graphEdges: nil,
            injectedMemoryIDs: nil,
            injectedMemoryTitles: nil,
            createdAt: loopRun.startedAt,
            updatedAt: loopRun.endedAt ?? now,
            completedAt: loopRun.endedAt,
            durationMs: nil
        )
    }

    func recordSubagentWorktreeError(_ error: Error, runID: UUID, parentSessionID: UUID) {
        let message = error.localizedDescription
        piAgentSessionStore.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
            run.worktreeStatus = .failed
            run.error = [run.error, message].compactMap { $0 }.joined(separator: "\n")
        }
        piAgentSessionStore.append(.init(sessionID: parentSessionID, role: .error, title: "Deck Agent Worktree Failed", text: message))
    }

    func respondToSubagentSupervisorRequest(_ requestID: String, parentSessionID: UUID, response: String) {
        nativeSubagentRunner.respondToSupervisorRequest(requestID, parentSessionID: parentSessionID, response: response)
    }

    func cancelSubagentSupervisorRequest(_ requestID: String, parentSessionID: UUID) {
        nativeSubagentRunner.cancelSupervisorRequest(requestID, parentSessionID: parentSessionID)
    }

    var areSubagentsEnabledForNewSessions: Bool {
        appSettingsController.areSubagentsEnabledForNewSessions
    }

    func setSubagentsEnabledForNewSessions(_ isEnabled: Bool) {
        guard appSettingsController.setSubagentsEnabledForNewSessions(isEnabled) else { return }
        syncAppSettings()
        piAgentSessionStore.newSessionSubagentsEnabled = isEnabled
    }

    func setNativeSubagentDelegationPolicy(_ policy: NativeSubagentDelegationPolicy) {
        guard appSettingsController.setNativeSubagentDelegationPolicy(policy) else { return }
        syncAppSettings()
    }

    func toggleSubagentsForNewSessions() {
        guard appSettingsController.toggleSubagentsForNewSessions() else { return }
        syncAppSettings()
        piAgentSessionStore.newSessionSubagentsEnabled = appSettings.nativeSubagentsEnabledForNewSessions
    }

    func setSubagentsEnabledForSelectedSession(_ isEnabled: Bool) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        setSubagentsEnabled(isEnabled, forSessionID: session.id)
    }

    func setSubagentsEnabled(_ isEnabled: Bool, forSessionID sessionID: UUID) {
        piAgentSessionStore.updateSession(sessionID, bumpUpdatedAt: false) { session in
            session.subagentsEnabled = session.isNoProject ? false : isEnabled
            if session.isNoProject {
                session.agentSelection = nil
            }
        }
        reconcileRunningSessionLaunchResourceFingerprints()
    }

    /// Draft-only footer control: before the first launch, subagents act like a
    /// session default. Update both the selected draft and the default for new
    /// sessions. Once Pi has started, the footer becomes read-only.
    func setSubagentsEnabledForSelectedDraftAndNewSessions(_ isEnabled: Bool) {
        guard let session = piAgentSessionStore.selectedSession, session.status == .draft else {
            setSubagentsEnabledForNewSessions(isEnabled)
            return
        }
        guard !session.isNoProject else {
            piAgentSessionStore.updateSession(session.id, bumpUpdatedAt: false) { session in
                session.subagentsEnabled = false
                session.agentSelection = nil
            }
            return
        }
        setSubagentsEnabledForNewSessions(isEnabled)
        piAgentSessionStore.updateSession(session.id, bumpUpdatedAt: false) { session in
            session.subagentsEnabled = isEnabled
        }
    }

    /// Persists a session's per-session subagent selection. `nil` restores the
    /// default (all effective agents); a non-nil set pins an explicit choice.
    /// Cached — see `cachedAllDisplayAgents`. Rebuilt by `rebuildWarningCaches()`.

}
