import Foundation

// MARK: - Session git ship, release, project server, worktree

extension AppViewModel {
    var shouldShowPiAgentGitActions: Bool {
        piAgentCommitMessageModel() != nil
    }

    /// Whether the dedicated "Release" toolbar button should appear: only when the
    /// selected session's repo is agent-deck itself. Matches the session's recorded
    /// `repository` (owner/repo), falling back to the project's GitHub remote.
    var shouldShowAgentDeckReleaseAction: Bool {
        guard let session = piAgentSessionStore.selectedSession else { return false }
        let target = ReleaseService.repository
        if let repository = session.repository,
           repository.caseInsensitiveCompare(target) == .orderedSame {
            return true
        }
        if let projectPath = session.projectPathForProjectFeatures,
           let remote = projectByPath[projectPath]?.gitHubRemote?.nameWithOwner,
           remote.caseInsensitiveCompare(target) == .orderedSame {
            return true
        }
        return false
    }

    /// The main checkout to tag against — the project path, never a worktree, so the
    /// release lands on `main` rather than a session's feature branch.
    var agentDeckReleaseProjectURL: URL? {
        guard let projectPath = piAgentSessionStore.selectedSession?.projectPathForProjectFeatures else { return nil }
        return URL(fileURLWithPath: projectPath, isDirectory: true)
    }

    /// Draft friendly release notes for the pending Agent Deck release using the
    /// default model (thinking off), from the commits since `sinceTag`. The
    /// returned markdown body is shown — and editable — in the release sheet, then
    /// rides the annotated tag into CI. Throws if no default model/project is
    /// available; the sheet treats that as "fall back to CI commit listing".
    func generateAgentDeckReleaseNotes(version: String, sinceTag: String?) async throws -> String {
        guard let model = defaultPiAgentModel() else {
            throw ReleaseNotesGenerationService.GenerationError.rpc(LanguageStore.shared.t("vm.noDefaultModel"))
        }
        guard let projectURL = agentDeckReleaseProjectURL else {
            throw ReleaseNotesGenerationService.GenerationError.rpc(LanguageStore.shared.t("vm.noProjectSelectedShort"))
        }
        let commits = try await gitRepositoryService.commitSubjects(sinceTag: sinceTag, in: projectURL)
        let environment = EnvRuntimeEnvironment().environment()
        return try await releaseNotesGenerator.generate(
            version: version,
            commitSubjects: commits,
            model: model,
            projectURL: projectURL,
            environment: environment
        )
    }

    /// Record a successful release in the selected session's transcript.
    func recordAgentDeckReleaseSucceeded(tag: String) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        piAgentSessionStore.append(.init(
            sessionID: session.id,
            role: .status,
            title: "Release Pushed",
            text: "Tagged and pushed \(tag). CI build is now running."
        ))
    }

    /// Whether the dev-server toolbar control should appear for the selected
    /// session: its project has a detectable dev server, or one is already
    /// running for it. Hidden for projects with no dev server (e.g. a Swift app)
    /// so the toolbar doesn't offer a control that can only report "none found".
    var shouldShowProjectServerControls: Bool {
        guard let path = piAgentSessionStore.selectedSession?.projectPathForProjectFeatures else { return false }
        if projectServerService.currentServer(forProjectPath: path) != nil { return true }
        return projectServerService.hasDetectedCommands(forProjectPath: path) == true
    }

    var shouldShowCommitSelectedPiAgentSession: Bool {
        guard shouldShowPiAgentGitActions,
              let session = piAgentSessionStore.selectedSession,
              let changes = repositoryChangesCache[session.repositoryRoot]?.snapshot else { return false }
        return changes.conflicted.isEmpty
            && (!changes.staged.isEmpty || !changes.unstaged.isEmpty || !changes.untracked.isEmpty)
    }

    var shouldShowPushSelectedPiAgentSession: Bool {
        guard shouldShowPiAgentGitActions,
              let session = piAgentSessionStore.selectedSession,
              let changes = repositoryChangesCache[session.repositoryRoot]?.snapshot else { return false }
        return changes.aheadCount > 0
    }

    var canCommitSelectedPiAgentSession: Bool {
        guard shouldShowCommitSelectedPiAgentSession,
              let session = piAgentSessionStore.selectedSession else { return false }
        return piAgentGitAutomationAction == nil && !session.status.isActive
    }

    var canPushSelectedPiAgentSession: Bool {
        guard shouldShowPushSelectedPiAgentSession,
              let session = piAgentSessionStore.selectedSession else { return false }
        return piAgentGitAutomationAction == nil && !session.status.isActive
    }

    var canCommitAndPushSelectedPiAgentSession: Bool { canCommitSelectedPiAgentSession }

    var shouldShowMergeSelectedPiAgentSession: Bool {
        guard shouldShowPiAgentGitActions,
              let session = piAgentSessionStore.selectedSession else { return false }
        return session.worktreePath != nil && session.branchName != nil && session.sourceBranch != nil
    }

    var canMergeSelectedPiAgentSession: Bool {
        guard shouldShowMergeSelectedPiAgentSession,
              let session = piAgentSessionStore.selectedSession,
              piAgentGitAutomationAction == nil,
              !session.status.isActive,
              let changes = repositoryChangesCache[session.repositoryRoot]?.snapshot else { return false }

        let hasUncommittedChanges = !changes.unstaged.isEmpty || !changes.untracked.isEmpty || !changes.conflicted.isEmpty || !changes.staged.isEmpty
        let hasCommittedBranchChanges = repositoryChangesCache[session.repositoryRoot]?.hasMergeableBranchChanges == true
        return hasUncommittedChanges || hasCommittedBranchChanges
    }

    func commitSelectedPiAgentSession() {
        shipSelectedPiAgentSession(pushAfterCommit: false)
    }

    func commitAndPushSelectedPiAgentSession() {
        shipSelectedPiAgentSession(pushAfterCommit: true)
    }

    func pushSelectedPiAgentSession() {
        guard let session = piAgentSessionStore.selectedSession else { return }
        let sessionID = session.id
        let branchName = session.branchName ?? "current branch"
        let projectURL = URL(fileURLWithPath: session.repositoryRoot, isDirectory: true)
        piAgentGitAutomationAction = .push
        Task { [weak self] in
            guard let self else { return }
            do {
                try await gitRepositoryService.pushCurrentBranch(in: projectURL)
                await MainActor.run {
                    self.piAgentGitAutomationAction = nil
                    self.piAgentSessionStore.append(.init(sessionID: sessionID, role: .status, title: "Push Completed", text: "Pushed \(branchName)"))
                    self.prepareRepoChangesForSelectedPiAgentSession(force: true)
                }
            } catch {
                await MainActor.run {
                    self.piAgentGitAutomationAction = nil
                    self.piAgentSessionStore.append(.init(sessionID: sessionID, role: .error, title: "Push Failed", text: error.localizedDescription))
                    self.prepareRepoChangesForSelectedPiAgentSession(force: true)
                }
            }
        }
    }

    /// Stages all changes in `workingURL`, generates an AI commit message, and commits.
    /// Throws `PiAgentShipService.ShipError.noChanges` when there is nothing to commit
    /// (caller decides whether that's fatal) and `.conflicts` when the working tree has
    /// unresolved merge conflicts. Shared by the Commit button and the Merge action.
    func performPiAgentAutoCommit(
        workingURL: URL,
        model: AvailableModel,
        environment: [String: String]
    ) async throws -> PiAgentShipService.CommitMessage {
        let before = try await gitRepositoryService.loadChanges(in: workingURL)
        if !before.conflicted.isEmpty { throw PiAgentShipService.ShipError.conflicts }
        if before.staged.isEmpty && before.unstaged.isEmpty && before.untracked.isEmpty {
            throw PiAgentShipService.ShipError.noChanges
        }

        try await gitRepositoryService.stageAll(in: workingURL)
        let status = try await gitRepositoryService.statusText(in: workingURL)
        let diff = try await gitRepositoryService.stagedDiffForCommitMessage(in: workingURL)
        let message = try await withCheckedThrowingContinuation { continuation in
            shipService.generateCommitMessage(status: status, diff: diff, model: model, projectURL: workingURL, environment: environment) { result in
                continuation.resume(with: result)
            }
        }
        try await gitRepositoryService.commit(message: message.title, description: message.body, in: workingURL)
        return message
    }

    func shipSelectedPiAgentSession(pushAfterCommit: Bool) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        guard let model = piAgentCommitMessageModel() else {
            piAgentSessionStore.append(.init(sessionID: session.id, role: .error, title: "Ship Failed", text: PiAgentShipService.ShipError.noModel.localizedDescription))
            return
        }

        let sessionID = session.id
        let projectURL = URL(fileURLWithPath: session.repositoryRoot, isDirectory: true)
        let environment = EnvRuntimeEnvironment().environment()
        piAgentGitAutomationAction = pushAfterCommit ? .commitAndPush : .commit

        Task { [weak self] in
            guard let self else { return }
            do {
                let message = try await self.performPiAgentAutoCommit(workingURL: projectURL, model: model, environment: environment)
                if pushAfterCommit {
                    try await gitRepositoryService.pushCurrentBranch(in: projectURL)
                }

                await MainActor.run {
                    self.piAgentGitAutomationAction = nil
                    self.piAgentSessionStore.append(.init(sessionID: sessionID, role: .status, title: pushAfterCommit ? "Commit & Push Completed" : "Commit Completed", text: pushAfterCommit ? "Committed and pushed “\(message.title)”" : "Committed “\(message.title)”"))
                    self.prepareRepoChangesForSelectedPiAgentSession(force: true)
                }
            } catch {
                await MainActor.run {
                    self.piAgentGitAutomationAction = nil
                    self.piAgentSessionStore.append(.init(sessionID: sessionID, role: .error, title: pushAfterCommit ? "Commit & Push Failed" : "Commit Failed", text: error.localizedDescription))
                    self.prepareRepoChangesForSelectedPiAgentSession(force: true)
                }
            }
        }
    }

    func startProjectServer(for session: PiAgentSessionRecord, command: ServerCommand) {
        guard let projectPath = session.projectPathForProjectFeatures else { return }
        projectServerService.start(command: command, projectPath: projectPath, projectName: session.projectName)
        piAgentSessionStore.append(.init(sessionID: session.id, role: .status, title: "Dev Server Started", text: "Started dev server."))
    }

    func stopProjectServer(for session: PiAgentSessionRecord, server: RunningServer) {
        projectServerService.stop(server)
        piAgentSessionStore.append(.init(sessionID: session.id, role: .status, title: "Dev Server Stopped", text: "Stopped dev server."))
    }

    func restartProjectServer(for session: PiAgentSessionRecord, server: RunningServer) {
        projectServerService.restart(server)
        piAgentSessionStore.append(.init(sessionID: session.id, role: .status, title: "Dev Server Restarted", text: "Restarted dev server."))
    }

    func mergeSelectedPiAgentSession() {
        guard let session = piAgentSessionStore.selectedSession,
              let projectPath = session.projectPathForProjectFeatures,
              let worktreePath = session.worktreePath,
              let branchName = session.branchName,
              let sourceBranch = session.sourceBranch else { return }
        guard let model = piAgentCommitMessageModel() else {
            piAgentSessionStore.append(.init(sessionID: session.id, role: .error, title: "Merge Failed", text: PiAgentShipService.ShipError.noModel.localizedDescription))
            return
        }
        let sessionID = session.id
        let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
        let worktreeURL = URL(fileURLWithPath: worktreePath, isDirectory: true)
        let environment = EnvRuntimeEnvironment().environment()
        let keepWorktreeAfterMerge = appSettings.piAgentSessionsKeepWorktreeAfterMerge
        piAgentGitAutomationAction = .merge

        Task { [weak self] in
            guard let self else { return }
            do {
                // 1. Auto-commit any uncommitted work in the worktree using the same
                //    code path as the Commit toolbar button. `.noChanges` is expected
                //    when the agent didn't touch files and is not an error here.
                do {
                    let message = try await self.performPiAgentAutoCommit(workingURL: worktreeURL, model: model, environment: environment)
                    await MainActor.run {
                        self.piAgentSessionStore.append(.init(sessionID: sessionID, role: .status, title: "Committed Changes", text: "Committed `\(message.title)` on `\(branchName)` before merging."))
                    }
                } catch PiAgentShipService.ShipError.noChanges {
                    // Nothing to stage — proceed; the commits-ahead check below decides.
                }

                // 2. Detect a no-op merge. Without this, `git merge --no-ff` of an
                //    already-merged branch silently reports "Already up to date." and
                //    the cleanup below would still remove the worktree.
                let ahead = try await self.gitRepositoryService.commitsAhead(branch: branchName, base: sourceBranch, in: projectURL)
                guard ahead > 0 else {
                    throw NSError(domain: "AgentDeckMerge", code: 3, userInfo: [NSLocalizedDescriptionKey: "Nothing to merge: `\(branchName)` has no commits ahead of `\(sourceBranch)`. The worktree and branch were left in place."])
                }

                // 3. Existing pre-merge checks on the parent repo.
                let parentClean = try await self.gitRepositoryService.isClean(in: projectURL)
                guard parentClean else {
                    throw NSError(domain: "AgentDeckMerge", code: 1, userInfo: [NSLocalizedDescriptionKey: "The project repository has uncommitted changes. Commit, stash, or discard them before merging."])
                }

                guard try await self.gitRepositoryService.hasBranch(sourceBranch, in: projectURL) else {
                    throw NSError(domain: "AgentDeckMerge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Source branch `\(sourceBranch)` no longer exists in the project."])
                }

                let parentBranch = try await self.gitRepositoryService.currentBranch(in: projectURL)
                if parentBranch != sourceBranch {
                    try await self.gitRepositoryService.checkoutBranch(sourceBranch, in: projectURL)
                }

                // 4. Merge.
                let outcome = try await self.gitRepositoryService.merge(branch: branchName, in: projectURL)
                switch outcome {
                case .success:
                    if keepWorktreeAfterMerge {
                        await MainActor.run {
                            self.piAgentGitAutomationAction = nil
                            self.piAgentSessionStore.append(.init(
                                sessionID: sessionID,
                                role: .status,
                                title: "Merge Completed",
                                text: "Merged \(branchName) into \(sourceBranch)."
                            ))
                            self.prepareRepoChangesForSelectedPiAgentSession(force: true)
                        }
                        return
                    }
                    await MainActor.run {
                        self.piAgentSessionStore.append(.init(sessionID: sessionID, role: .status, title: "Merge Completed", text: "Merged \(branchName) into \(sourceBranch)"))
                    }
                    // The merge has already landed on `sourceBranch`. Anything that goes
                    // wrong from here is a cleanup problem, not a merge problem — surface
                    // it that way so the transcript doesn't read like the merge itself failed.
                    let cleanupResult: Result<PiAgentBranchDeletionOutcome, Error>
                    do {
                        let outcome = try await self.sessionWorktreeService.removeWorktree(
                            worktreePath: worktreeURL.path,
                            projectURL: projectURL,
                            branchName: branchName,
                            sourceBranch: sourceBranch,
                            deleteBranch: true
                        )
                        cleanupResult = .success(outcome)
                    } catch {
                        cleanupResult = .failure(error)
                    }
                    await MainActor.run {
                        self.piAgentGitAutomationAction = nil
                        switch cleanupResult {
                        case .success(let cleanupOutcome):
                            // The worktree directory was removed (the only paths inside
                            // `removeWorktree` that affect persisted state run before the
                            // function returns). Forget the worktree on the session record;
                            // keep the branch reference iff the branch survived.
                            self.piAgentSessionStore.updateSession(sessionID) { record in
                                record.worktreePath = nil
                                record.sourceBranch = nil
                                switch cleanupOutcome {
                                case .deleted, .skippedNoBranchName, .skippedNotRequested:
                                    record.branchName = nil
                                case .retainedUnmerged:
                                    break
                                }
                            }
                            switch cleanupOutcome {
                            case .deleted:
                                self.piAgentSessionStore.append(.init(sessionID: sessionID, role: .status, title: LanguageStore.shared.t("vm.worktreeRemoved"), text: LanguageStore.shared.t("vm.removedWorktreeBranch", branchName)))
                            case .skippedNoBranchName, .skippedNotRequested:
                                self.piAgentSessionStore.append(.init(sessionID: sessionID, role: .status, title: LanguageStore.shared.t("vm.worktreeRemoved"), text: LanguageStore.shared.t("vm.removedWorktree")))
                            case let .retainedUnmerged(reason):
                                self.piAgentSessionStore.append(.init(sessionID: sessionID, role: .error, title: "Branch Retained", text: "Merged into `\(sourceBranch)` and removed the worktree, but branch `\(branchName)` was not deleted: \(reason). Delete it manually with `git branch -D \(branchName)` once you've checked."))
                            }
                        case .failure(let cleanupError):
                            // `removeWorktree` only throws before any cleanup runs, so the
                            // worktree directory and branch are still on disk. Don't clear
                            // session fields — the user needs them to investigate.
                            self.piAgentSessionStore.append(.init(sessionID: sessionID, role: .error, title: "Worktree Cleanup Failed", text: "The merge into `\(sourceBranch)` succeeded, but the worktree at `\(worktreeURL.path)` could not be cleaned up: \(cleanupError.localizedDescription)."))
                        }
                        self.prepareRepoChangesForSelectedPiAgentSession(force: true)
                    }
                case let .conflict(status):
                    await MainActor.run {
                        self.piAgentGitAutomationAction = nil
                        self.piAgentSessionStore.append(.init(sessionID: sessionID, role: .error, title: "Merge Conflict", text: "Merge of `\(branchName)` into `\(sourceBranch)` left conflicts. Resolve them in the project, then commit.\n\n\(status)"))
                        self.prepareRepoChangesForSelectedPiAgentSession(force: true)
                    }
                }
            } catch let skipError as NSError where skipError.domain == "AgentDeckMerge" && skipError.code == 3 {
                await MainActor.run {
                    self.piAgentGitAutomationAction = nil
                    self.piAgentSessionStore.append(.init(sessionID: sessionID, role: .error, title: "Merge Skipped", text: skipError.localizedDescription))
                    self.prepareRepoChangesForSelectedPiAgentSession(force: true)
                }
            } catch {
                await MainActor.run {
                    self.piAgentGitAutomationAction = nil
                    self.piAgentSessionStore.append(.init(sessionID: sessionID, role: .error, title: "Merge Failed", text: error.localizedDescription))
                    self.prepareRepoChangesForSelectedPiAgentSession(force: true)
                }
            }
        }
    }

    /// Creates a session worktree for the given project if the user opted in via
    /// settings. Posts a status entry to the session's transcript on success or
    /// failure. Called lazily, right before the session's first message launches
    /// Pi — drafts stay pure records until then, so abandoning one never leaves
    /// a worktree or branch behind. Callers must await this before starting the
    /// agent so Pi launches in the worktree on the very first turn.
    func provisionWorktreeIfEnabled(for sessionID: UUID, project: DiscoveredProject) async {
        guard appSettings.piAgentSessionsUseWorktree else { return }
        guard project.isGitRepository else {
            piAgentSessionStore.append(.init(sessionID: sessionID, role: .status, title: "Worktree Skipped", text: "Worktree isolation is enabled, but the project is not a git repository. Running in the project root."))
            return
        }
        do {
            let creation = try await sessionWorktreeService.createWorktree(for: sessionID, projectURL: project.url)
            piAgentSessionStore.updateSession(sessionID) { record in
                record.worktreePath = creation.worktreePath
                record.branchName = creation.branchName
                record.sourceBranch = creation.sourceBranch
            }
            piAgentSessionStore.append(.init(sessionID: sessionID, role: .status, title: "Worktree Ready", text: "Created branch `\(creation.branchName)` off `\(creation.sourceBranch)` in an isolated worktree."))
        } catch {
            piAgentSessionStore.append(.init(sessionID: sessionID, role: .error, title: "Worktree Setup Failed", text: "Could not create a session worktree: \(error.localizedDescription). The session will run in the project root."))
        }
    }

}
