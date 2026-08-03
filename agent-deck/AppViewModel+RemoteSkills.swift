import Foundation

// MARK: - Remote skill repositories

extension AppViewModel {
    // MARK: - Remote skill repositories

    /// The synced repository whose clone contains `skill`, if any.
    func importedRepository(for skill: SkillRecord) -> ImportedSkillRepository? {
        appSettings.importedSkillRepositories.first { $0.contains(skillFilePath: skill.filePath) }
    }

    /// The synced repository explicitly associated with a Git-backed skill
    /// collection. Local/user-organized collections intentionally return nil.
    func importedRepository(for collection: SkillCollectionRecord) -> ImportedSkillRepository? {
        guard let repositoryID = collection.importedRepositoryID else { return nil }
        return appSettings.importedSkillRepositories.first { $0.id == repositoryID }
    }

    /// Resolve a pasted GitHub / skills.sh URL, clone it for discovery (or
    /// reuse an existing clone when the repo is already imported), and list
    /// its skills.
    func prepareRemoteSkillImport(
        from rawInput: String,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async throws -> RemoteSkillImportContext {
        let source = try SkillRepositorySyncService.resolveSource(from: rawInput)
        let existing = appSettings.importedSkillRepositories.first {
            $0.owner.caseInsensitiveCompare(source.owner) == .orderedSame
                && $0.repo.caseInsensitiveCompare(source.repo) == .orderedSame
        }

        if let existing {
            let clonePath = URL(fileURLWithPath: existing.clonePath, isDirectory: true)
            let candidates = try await skillRepositorySyncService.listSkills(
                inCloneAt: clonePath,
                directoryConstraint: source.preselectedSkillDirectory,
                progress: progress
            )
            return RemoteSkillImportContext(
                source: source,
                clonePath: clonePath,
                resolvedRef: existing.ref,
                headCommit: existing.lastSyncedCommit,
                candidates: candidates,
                existingRepository: existing
            )
        }

        let clonePath = SkillRepositorySyncService.cloneDirectoryURL(owner: source.owner, repo: source.repo)
        let info = try await skillRepositorySyncService.cloneForDiscovery(source, into: clonePath)
        let candidates = try await skillRepositorySyncService.listSkills(
            inCloneAt: clonePath,
            directoryConstraint: source.preselectedSkillDirectory,
            progress: progress
        )
        return RemoteSkillImportContext(
            source: source,
            clonePath: clonePath,
            resolvedRef: info.resolvedRef,
            headCommit: info.headCommit,
            candidates: candidates,
            existingRepository: nil
        )
    }

    /// Sparse-check-out the selected skills, register their roots in the
    /// catalog, and record (or extend) the synced-repository entry.
    func importRemoteSkills(
        context: RemoteSkillImportContext,
        selectedCandidates: [RemoteSkillCandidate],
        collectionName: String?
    ) async throws -> SkillImportResult {
        guard !selectedCandidates.isEmpty else {
            return SkillImportResult(importedNames: [], skippedNames: [])
        }

        let requestedCollectionName = collectionName?.trimmingCharacters(in: .whitespacesAndNewlines)

        try await skillRepositorySyncService.checkout(
            selectedCandidates,
            inCloneAt: context.clonePath,
            additive: context.existingRepository != nil
        )

        let rootPaths = selectedCandidates.map { skillRootPath(for: $0, clonePath: context.clonePath) }
        appSettingsController.addExternalSkillPaths(rootPaths)

        var syncedDirectories = Set(context.existingRepository?.syncedSkillRelativePaths ?? [])
        syncedDirectories.formUnion(selectedCandidates.map(\.repoRelativeDirectory))

        let repositoryID = context.existingRepository?.id ?? UUID()
        let record = ImportedSkillRepository(
            id: repositoryID,
            remoteURL: context.source.remoteURL,
            owner: context.source.owner,
            repo: context.source.repo,
            ref: context.resolvedRef,
            clonePath: context.clonePath.standardizedFileURL.path,
            syncedSkillRelativePaths: syncedDirectories.sorted(),
            lastSyncedCommit: context.headCommit,
            lastSyncedDate: Date(),
            lastCheckedDate: context.existingRepository?.lastCheckedDate,
            latestKnownRemoteCommit: context.existingRepository?.latestKnownRemoteCommit
        )
        appSettingsController.upsertImportedSkillRepository(record)
        if let collectionName = requestedCollectionName, !collectionName.isEmpty {
            upsertSkillCollection(
                name: collectionName,
                description: LanguageStore.shared.t("vm.syncedGitSkillCollection"),
                skillRootPaths: rootPaths,
                skillNames: Set(selectedCandidates.map(\.name)),
                importedRepositoryID: repositoryID,
                sourceLabel: "GitHub · \(record.displayName)"
            )
        }
        appSettings = appSettingsController.settings

        refresh(includeModels: false, scanAllProjects: true)
        if let firstName = selectedCandidates.first?.name {
            selectedSkillID = allVisibleSkillRecords.first { $0.name == firstName }?.id ?? selectedSkillID
        }
        return SkillImportResult(importedNames: selectedCandidates.map(\.name), skippedNames: [])
    }

    /// Delete a discovery clone the user fetched but never imported from.
    func discardDiscoveryClone(_ context: RemoteSkillImportContext) {
        guard context.isFreshClone else { return }
        let path = context.clonePath.standardizedFileURL.path
        let isReferenced = appSettings.importedSkillRepositories.contains {
            URL(fileURLWithPath: $0.clonePath).standardizedFileURL.path == path
        }
        guard !isReferenced else { return }
        try? FileManager.default.removeItem(at: context.clonePath)
    }

    func skillRootPath(for candidate: RemoteSkillCandidate, clonePath: URL) -> String {
        let root = candidate.isWholeRepository
            ? clonePath
            : clonePath.appendingPathComponent(candidate.repoRelativeDirectory, isDirectory: true)
        return root.standardizedFileURL.path
    }

    /// Manual "Check for Updates": a network-only `git ls-remote`. The result
    /// is recorded so the skill detail can show an "update available" badge.
    @discardableResult
    func checkSkillRepositoryForUpdate(_ repository: ImportedSkillRepository) async throws -> SkillRepositoryUpdateStatus {
        let status = try await skillRepositorySyncService.checkForUpdate(
            remoteURL: repository.remoteURL,
            ref: repository.ref,
            syncedCommit: repository.lastSyncedCommit
        )
        var updated = repository
        updated.lastCheckedDate = Date()
        switch status {
        case .upToDate:
            updated.latestKnownRemoteCommit = repository.lastSyncedCommit
        case let .updateAvailable(remoteCommit):
            updated.latestKnownRemoteCommit = remoteCommit
        }
        appSettingsController.upsertImportedSkillRepository(updated)
        appSettings = appSettingsController.settings
        return status
    }

    /// Fetch and fast-forward a synced repository. Returns `.conflicts` when an
    /// in-place edit collides with an upstream change for the caller to resolve.
    func updateSkillRepository(_ repository: ImportedSkillRepository) async throws -> SkillRepositoryUpdateOutcome {
        let outcome = try await skillRepositorySyncService.update(
            cloneAt: URL(fileURLWithPath: repository.clonePath, isDirectory: true),
            ref: repository.ref
        )
        applyUpdateOutcome(outcome, to: repository)
        return outcome
    }

    /// Apply an update after the user chose Keep Mine / Take Remote per file.
    func resolveSkillRepositoryUpdate(
        _ repository: ImportedSkillRepository,
        resolutions: [String: SkillConflictResolution]
    ) async throws -> SkillRepositoryUpdateOutcome {
        let outcome = try await skillRepositorySyncService.resolveConflicts(
            cloneAt: URL(fileURLWithPath: repository.clonePath, isDirectory: true),
            ref: repository.ref,
            resolutions: resolutions
        )
        applyUpdateOutcome(outcome, to: repository)
        return outcome
    }

    func applyUpdateOutcome(_ outcome: SkillRepositoryUpdateOutcome, to repository: ImportedSkillRepository) {
        // Reconcile the stored record to the clone's real HEAD for both a fresh
        // fast-forward and the "already up to date" case. The latter matters when
        // the clone advanced earlier but the record was left stale — otherwise the
        // "update available" badge sticks even though there's nothing to pull.
        let resolvedCommit: String
        let didChangeFiles: Bool
        switch outcome {
        case let .updated(newCommit):
            resolvedCommit = newCommit
            didChangeFiles = true
        case let .alreadyUpToDate(commit):
            resolvedCommit = commit
            didChangeFiles = false
        case .conflicts:
            return
        }

        var updated = repository
        let commitChanged = updated.lastSyncedCommit != resolvedCommit
        updated.lastSyncedCommit = resolvedCommit
        updated.latestKnownRemoteCommit = resolvedCommit
        if commitChanged { updated.lastSyncedDate = Date() }
        updated.lastCheckedDate = Date()
        appSettingsController.upsertImportedSkillRepository(updated)
        appSettings = appSettingsController.settings
        if didChangeFiles { refresh(includeModels: false, scanAllProjects: true) }
    }

    /// Synced repositories a manual check has flagged as having an upstream update.
    var skillRepositoriesWithKnownUpdates: [ImportedSkillRepository] {
        appSettings.importedSkillRepositories.filter(\.hasKnownUpdate)
    }

    /// Run a manual update check across every synced skill repository.
    func checkAllSkillRepositoriesForUpdates() async {
        guard !isCheckingAllSkillUpdates, !isUpdatingAllSkillRepositories else { return }
        let repositories = appSettings.importedSkillRepositories
        guard !repositories.isEmpty else { return }

        isCheckingAllSkillUpdates = true
        defer { isCheckingAllSkillUpdates = false }

        var failures = 0
        for repository in repositories {
            do { _ = try await checkSkillRepositoryForUpdate(repository) }
            catch { failures += 1 }
        }

        let updateCount = skillRepositoriesWithKnownUpdates.count
        if failures > 0 {
            skillBatchActionMessage = "Checked \(repositories.count) skill repositor\(repositories.count == 1 ? "y" : "ies"). \(updateCount) ha\(updateCount == 1 ? "s" : "ve") an update available. \(failures) could not be checked."
        } else if updateCount == 0 {
            skillBatchActionMessage = LanguageStore.shared.t("vm.skillsAllUpToDate")
        }
        // When updates were found and nothing failed, the per-row badges show
        // the result — no alert needed.
    }

    /// Apply updates to every synced repository a check has flagged. Repositories
    /// whose local edits conflict with upstream are skipped and reported so the
    /// user can resolve them one at a time.
    func updateAllSkillRepositoriesWithKnownUpdates() async {
        guard !isUpdatingAllSkillRepositories, !isCheckingAllSkillUpdates else { return }
        let targets = skillRepositoriesWithKnownUpdates
        guard !targets.isEmpty else { return }

        isUpdatingAllSkillRepositories = true
        defer { isUpdatingAllSkillRepositories = false }

        var updated = 0
        var conflicted = 0
        var failed = 0
        for target in targets {
            // Re-read the record — an earlier iteration may have mutated settings.
            guard let current = appSettings.importedSkillRepositories.first(where: { $0.id == target.id }) else { continue }
            do {
                switch try await updateSkillRepository(current) {
                case .updated: updated += 1
                case .alreadyUpToDate: break
                case .conflicts: conflicted += 1
                }
            } catch {
                failed += 1
            }
        }

        var parts: [String] = []
        if updated > 0 {
            parts.append("Updated \(updated) skill\(updated == 1 ? "" : "s").")
        }
        if conflicted > 0 {
            parts.append("\(conflicted) skill\(conflicted == 1 ? " has" : "s have") local edits that conflict with the update — open each skill to resolve.")
        }
        if failed > 0 {
            parts.append("\(failed) skill\(failed == 1 ? "" : "s") could not be updated.")
        }
        skillBatchActionMessage = parts.isEmpty ? LanguageStore.shared.t("vm.skillsNoUpdateNeeded") : parts.joined(separator: "\n\n")
    }

}
