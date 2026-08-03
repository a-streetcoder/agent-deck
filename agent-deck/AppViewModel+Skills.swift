import AppKit
import Foundation
import SwiftUI

// MARK: - Skills import, assignment, collections

extension AppViewModel {
    var suggestedExternalSkillsDirectoryURL: URL {
        let fileManager = FileManager.default
        func isDirectory(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }

        let globalSkills = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/skills", isDirectory: true)
        return isDirectory(globalSkills) ? globalSkills : fileManager.homeDirectoryForCurrentUser
    }

    func chooseExternalSkillsDirectory(startingAt url: URL? = nil, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = LanguageStore.shared.t("vm.chooseSkillsFolder")
        panel.message = LanguageStore.shared.t("vm.chooseSkillsFolderMessage", AppBrand.displayName)
        panel.directoryURL = url ?? suggestedExternalSkillsDirectoryURL

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            DispatchQueue.main.async {
                guard response == .OK,
                      let selectedURL = panel.url?.standardizedFileURL else {
                    completion(nil)
                    return
                }
                completion(selectedURL)
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    func importExternalSkills(
        _ candidates: [ExternalSkillCandidate],
        collectionName: String?
    ) throws -> SkillImportResult {
        var importedNames: [String] = []
        var skippedNames: [String] = []
        var importedPaths: [String] = []
        var importedCandidates: [ExternalSkillCandidate] = []
        let requestedCollectionName = collectionName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingPaths = appSettings.externalSkillPaths

        for candidate in candidates {
            let sourceURL = URL(fileURLWithPath: candidate.sourceRootPath)
            let sourcePath = sourceURL.standardizedFileURL.path
            if existingPaths.contains(sourcePath) {
                skippedNames.append(candidate.name)
                continue
            }
            importedPaths.append(sourcePath)
            importedNames.append(candidate.name)
            importedCandidates.append(candidate)
        }

        if appSettingsController.addExternalSkillPaths(importedPaths) {
            appSettings = appSettingsController.settings
        }
        if !importedPaths.isEmpty, let collectionName = requestedCollectionName, !collectionName.isEmpty {
            let sourceRoots = Set(importedCandidates.map { URL(fileURLWithPath: $0.sourceRootPath).standardizedFileURL.path })
            let commonRoot = commonAncestorPath(for: Array(sourceRoots))
            upsertSkillCollection(
                name: collectionName,
                description: LanguageStore.shared.t("vm.localSkillCollection"),
                skillRootPaths: importedPaths,
                skillNames: Set(importedNames),
                importedRepositoryID: nil,
                sourceLabel: commonRoot.map { "Local · \($0)" }
            )
            appSettings = appSettingsController.settings
        }
        refresh(includeModels: false, scanAllProjects: true)
        if let firstImported = importedNames.first {
            selectedSkillID = allVisibleSkillRecords.first { $0.name == firstImported }?.id ?? selectedSkillID
        }
        return SkillImportResult(importedNames: importedNames, skippedNames: skippedNames)
    }

    func importKnownSkills(
        _ candidates: [SkillImportSheet.KnownSkillCandidate],
        collectionName: String?
    ) throws -> SkillImportResult {
        let existingPaths = appSettings.externalSkillPaths
        let existingReferences = appSettings.codexPluginSkillReferences
        var paths: [String] = []
        var references = Set<CodexPluginSkillReference>()
        var importedNames: [String] = []
        var skippedNames: [String] = []
        for candidate in candidates {
            if let reference = candidate.pluginReference {
                if existingReferences.contains(reference) { skippedNames.append(candidate.external.name) }
                else { references.insert(reference); importedNames.append(candidate.external.name) }
            } else {
                let path = URL(fileURLWithPath: candidate.external.sourceRootPath).standardizedFileURL.path
                if existingPaths.contains(path) { skippedNames.append(candidate.external.name) }
                else { paths.append(path); importedNames.append(candidate.external.name) }
            }
        }
        let addedPaths = appSettingsController.addExternalSkillPaths(paths)
        let addedReferences = appSettingsController.addCodexPluginSkillReferences(references)
        if addedPaths || addedReferences { appSettings = appSettingsController.settings }
        if !importedNames.isEmpty, let name = collectionName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let roots = Set(paths)
            upsertSkillCollection(
                name: name,
                description: references.isEmpty ? "Local skill collection" : "Claude / Codex skill collection",
                skillRootPaths: paths,
                skillNames: Set(importedNames),
                importedRepositoryID: nil,
                sourceLabel: references.isEmpty ? commonAncestorPath(for: Array(roots)).map { "Local · \($0)" } : "Codex Plugin"
            )
            appSettings = appSettingsController.settings
        }
        if addedPaths || addedReferences { refresh(includeModels: false, scanAllProjects: true) }
        return SkillImportResult(importedNames: importedNames, skippedNames: skippedNames)
    }

    func commonAncestorPath(for paths: [String]) -> String? {
        guard var components = paths.first.map({ URL(fileURLWithPath: $0).standardizedFileURL.pathComponents }) else { return nil }
        for path in paths.dropFirst() {
            let next = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
            components = Array(zip(components, next).prefix { $0 == $1 }.map(\.0))
            if components.isEmpty { return nil }
        }
        return NSString.path(withComponents: components)
    }

    func upsertSkillCollection(
        name: String,
        description: String?,
        skillRootPaths: [String],
        skillNames: Set<String>,
        importedRepositoryID: UUID?,
        sourceLabel: String?
    ) {
        let standardizedPaths = Set(skillRootPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        guard !standardizedPaths.isEmpty || !skillNames.isEmpty else { return }
        let existing = appSettingsController.settings.skillCollections.first { collection in
            if let importedRepositoryID, collection.importedRepositoryID == importedRepositoryID { return true }
            return collection.importedRepositoryID == nil && collection.name == name && collection.sourceLabel == sourceLabel
        }
        var collection = existing ?? SkillCollectionRecord(
            name: name,
            description: description,
            skillRootPaths: [],
            skillNames: [],
            importedRepositoryID: importedRepositoryID,
            sourceLabel: sourceLabel
        )
        collection.description = description ?? collection.description
        collection.skillRootPaths.formUnion(standardizedPaths)
        collection.skillNames.formUnion(skillNames)
        collection.importedRepositoryID = importedRepositoryID ?? collection.importedRepositoryID
        collection.sourceLabel = sourceLabel ?? collection.sourceLabel
        appSettingsController.upsertSkillCollection(collection)
    }
















    func bundledSkillIsDisabled(_ skill: SkillRecord) -> Bool {
        skill.source.kind == .builtin && appSettings.disabledBundledSkillNames.contains(skill.name)
    }

    func setBundledSkillDisabled(_ isDisabled: Bool, for skill: SkillRecord) {
        guard skill.source.kind == .builtin else { return }
        guard appSettingsController.setBundledSkillDisabled(skill.name, isDisabled: isDisabled) else { return }
        appSettings = appSettingsController.settings
        refresh(includeModels: false)
    }

    func explicitSkillVisibilityIssues(for agent: EffectiveAgentRecord) -> [AgentSkillVisibilityIssue] {
        cachedSkillVisibilityIssuesByAgentID[agent.id] ?? []
    }

    func skillNamed(_ skillName: String, isRuntimeVisibleIn project: DiscoveredProject) -> Bool {
        skillCatalog(forProjectPath: project.path).filter { $0.name == skillName }.count == 1
    }

    func unavailableSkillResolutionCandidate(for warning: SkillReferenceWarning) -> SkillRecord? {
        let records = deduplicateByID(
            allVisibleSkillRecords + allProjectSnapshots.values.flatMap { $0.skills + $0.librarySkills }
        )
        return records
            .filter { $0.name == warning.missingSkill }
            .filter { !skillNamed($0.name, isRuntimeVisibleIn: warning.project) }
            .sorted { lhs, rhs in
                let lhsIsProject = lhs.source.kind == .project || lhs.source.kind == .legacyProject
                let rhsIsProject = rhs.source.kind == .project || rhs.source.kind == .legacyProject
                if lhsIsProject != rhsIsProject { return lhsIsProject && !rhsIsProject }
                return lhs.filePath < rhs.filePath
            }
            .first
    }

    func moveSkillToGlobalCatalog(_ skill: SkillRecord) throws {
        try moveSkillToGlobalDirectory(skill)
        refresh(includeModels: false, scanAllProjects: true)
    }

    /// Recomputes cached model lists/lookups. Called only at real boundaries —
    /// app launch / activation, a model-list reload, or a settings change —

    func addSkillToSelectedProject(_ skill: SkillRecord) throws {
        guard let selectedProjectPath else { throw CocoaError(.fileNoSuchFile) }
        try setSkill(skill, enabled: true, forProjectPath: selectedProjectPath)
    }

    func removeSkillFromSelectedProject(_ skill: SkillRecord) throws {
        guard let selectedProjectPath else { throw CocoaError(.fileNoSuchFile) }
        try setSkill(skill, enabled: false, forProjectPath: selectedProjectPath)
    }

    func setSkill(_ skill: SkillRecord, enabled: Bool, for project: DiscoveredProject) throws {
        try setSkill(skill, enabled: enabled, forProjectPath: project.path)
    }

    func skill(_ skill: SkillRecord, isEnabledFor project: DiscoveredProject) -> Bool {
        projectPreference(for: project.path).assignedSkillNames.contains(skill.name)
    }

    func assignedProjects(for skill: SkillRecord) -> [DiscoveredProject] {
        enabledProjects.filter { self.skill(skill, isEnabledFor: $0) }
    }

    func skill(_ skill: SkillRecord, isAssignedTo agent: EffectiveAgentRecord) -> Bool {
        agent.resolved.skills.contains(skill.name)
    }

    func setSkill(_ skill: SkillRecord, enabled: Bool, for agent: EffectiveAgentRecord) throws {
        try setAgentSkillName(skill.name, enabled: enabled, for: agent)
    }

    func assignedAgents(for skillRecord: SkillRecord) -> [EffectiveAgentRecord] {
        snapshot.effectiveAgents.filter { skill(skillRecord, isAssignedTo: $0) }
    }

    func skillCollection(_ collection: SkillCollectionRecord, isAssignedTo agent: EffectiveAgentRecord) -> Bool {
        agent.resolved.skills.contains(collection.name)
    }

    func setSkillCollection(_ collection: SkillCollectionRecord, enabled: Bool, for agent: EffectiveAgentRecord) throws {
        try setAgentSkillName(collection.name, enabled: enabled, for: agent)
    }

    func assignedAgents(for collection: SkillCollectionRecord) -> [EffectiveAgentRecord] {
        snapshot.effectiveAgents.filter { skillCollection(collection, isAssignedTo: $0) }
    }

    func setAgentSkillName(_ name: String, enabled: Bool, for agent: EffectiveAgentRecord) throws {
        guard var draft = makeAgentDraft(for: agent) else { throw CocoaError(.fileNoSuchFile) }
        var skills = draft.config.skills
        if enabled {
            if !skills.contains(name) { skills.append(name) }
        } else {
            skills.removeAll { $0 == name }
        }
        draft.config.skills = PiSkillLaunchResolver.normalizedNames(skills)
        try saveAgentDraft(draft, for: agent)
        // `saveAgentDraft` rewrites the agent `.md` and schedules a background
        // rescan, but the toggle's checkbox is snapshot-derived. Patch the
        // in-memory effective agent so the checkbox flips immediately instead
        // of waiting for that rescan to land.
        patchEffectiveAgentSkills(agentName: agent.name, skills: draft.config.skills)
        rebuildWarningCaches()
        reconcileRunningSessionLaunchResourceFingerprints()
    }

    func setSkill(_ skill: SkillRecord, enabled: Bool, forProjectPath projectPath: String) throws {
        projectPreferencesStore.setAssignedSkill(skill.name, assigned: enabled, for: projectPath)
        applyProjectPreferenceChanges()
        // Project assignment only mutates UserDefaults — nothing on disk
        // changed. Reconcile snapshot-derived state in memory instead of
        // re-walking the filesystem, so the toggle is instant.
        reconcileSnapshotsFromPreferences()
        selectedSkillID = allVisibleSkillRecords.first { $0.name == skill.name }?.id ?? selectedSkillID
    }

    func enableSkillGlobally(_ skill: SkillRecord) throws {
        guard appSettingsController.setDefaultSkill(skill.name, enabled: true) else {
            refresh(includeModels: false, scanAllProjects: true)
            selectedSkillID = allVisibleSkillRecords.first { $0.name == skill.name }?.id ?? selectedSkillID
            return
        }
        appSettings = appSettingsController.settings
        refresh(includeModels: false, scanAllProjects: true)
        selectedSkillID = allVisibleSkillRecords.first { $0.name == skill.name }?.id ?? selectedSkillID
    }

    func disableSkillGlobally(_ skill: SkillRecord) throws {
        guard appSettingsController.setDefaultSkill(skill.name, enabled: false) else { return }
        appSettings = appSettingsController.settings
        refresh(includeModels: false)
    }

    func canDeleteSkill(_ skill: SkillRecord) -> Bool {
        switch skill.source.kind {
        case .builtin, .package:
            return false
        case .global, .project, .legacyProject, .override, .library:
            return true
        }
    }

    /// Filesystem + state mutations for deleting one skill, WITHOUT triggering
    /// a refresh. The caller is responsible for calling `refresh()` once after
    /// all desired deletions — single call sites do it inline, batch call sites
    /// do it once after the loop.
    func performSkillDeletion(_ skill: SkillRecord) throws {
        guard canDeleteSkill(skill) else { throw CocoaError(.fileWriteNoPermission) }
        // Codex plugin packages are owned by Codex. "Delete" means un-import,
        // never modifying or trashing a cache file.
        if cachedResolvedCodexPluginSkillPaths.values.contains(skillDeletionTargetURL(for: skill).standardizedFileURL.path) {
            try performSkillCatalogRemoval(skill)
            return
        }

        // Throwing filesystem work first — optimistic hiding must not happen
        // unless these succeed (SkillsScreen shows an alert on throw).
        let targetURL = skillDeletionTargetURL(for: skill)
        try removeSkillReferences(named: skill.name)
        try FileManager.default.trashItem(at: targetURL, resultingItemURL: nil)
        removeExternalSkillCatalogReferences(for: skill, deletedTarget: targetURL)
        unlistSkillFromSyncedRepository(skill)

        // Hide the row immediately — no blocking rescan. SwiftUI updates the
        // list the instant the published set changes, like session deletion.
        withAnimation(.snappy(duration: 0.18)) {
            _ = pendingDeletedSkillIDs.insert(skill.id)
        }
        // Recompute selection AFTER hiding so the deleted skill isn't re-picked.
        selectedSkillID = allVisibleSkillRecords.first?.id
    }

    func deleteSkill(_ skill: SkillRecord) throws {
        try performSkillDeletion(skill)
        // Reconcile in the background; applyRefreshSnapshot prunes the pending
        // ID once the fresh snapshot confirms the skill is gone. `silentlyReconcile`
        // because `pendingDeletedSkillIDs.insert` already hid the row.
        refresh(includeModels: false, scanAllProjects: true, silentlyReconcile: true)
    }

    /// Batch delete: filesystem work per skill, then a single refresh. Returns
    /// the names of skills whose deletion threw (e.g. protected source kinds).
    /// Avoids the N-refresh storm of looping `deleteSkill(_:)`.
    func deleteSkills(_ skills: [SkillRecord]) -> [String] {
        var failed: [String] = []
        for skill in skills {
            do { try performSkillDeletion(skill) }
            catch { failed.append(skill.name) }
        }
        if skills.count > failed.count {
            refresh(includeModels: false, scanAllProjects: true, silentlyReconcile: true)
        }
        return failed
    }

    /// True when `skill` was imported — its root path is tracked in
    /// `externalSkillPaths` (a local-folder import or a Git-synced repo skill).
    func isImportedSkill(_ skill: SkillRecord) -> Bool {
        let filePath = URL(fileURLWithPath: skill.filePath).standardizedFileURL.path
        let rootPath = skillDeletionTargetURL(for: skill).standardizedFileURL.path
        if cachedResolvedCodexPluginSkillPaths.values.contains(where: { $0 == rootPath || $0 == filePath }) { return true }
        let paths = cachedStandardizedExternalSkillPaths
        return paths.contains(filePath) || paths.contains(rootPath)
    }

    /// Filesystem + state mutations for un-importing one skill, WITHOUT
    /// triggering a refresh. See `performSkillDeletion(_:)` for rationale.
    func performSkillCatalogRemoval(_ skill: SkillRecord) throws {
        guard isImportedSkill(skill) else { throw CocoaError(.fileWriteNoPermission) }

        let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
        let rootURL = skillDeletionTargetURL(for: skill).standardizedFileURL
        let pluginReferences = Set(cachedResolvedCodexPluginSkillPaths.compactMap { reference, path in
            path == rootURL.path || path == fileURL.path ? reference : nil
        })

        // Clear name-based assignments so no dangling missing-skill warning is
        // left behind — same as deletion, minus the trashing.
        try removeSkillReferences(named: skill.name)

        let pathsToRemove = appSettings.externalSkillPaths.filter { rawPath in
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            return path == rootURL.path || path == fileURL.path
        }
        let removedPath = appSettingsController.removeExternalSkillPaths(pathsToRemove)
        let removedPlugin = appSettingsController.removeCodexPluginSkillReferences(pluginReferences)
        if removedPath || removedPlugin { appSettings = appSettingsController.settings }
        unlistSkillFromSyncedRepository(skill)

        withAnimation(.snappy(duration: 0.18)) {
            _ = pendingDeletedSkillIDs.insert(skill.id)
        }
        selectedSkillID = allVisibleSkillRecords.first?.id
    }

    /// Un-import a skill: drop it from the catalog without trashing its files.
    /// For a Git-synced skill the repository clone is kept; the skill is just
    /// un-listed from that repository's synced set.
    func removeSkillFromCatalog(_ skill: SkillRecord) throws {
        try performSkillCatalogRemoval(skill)
        refresh(includeModels: false, scanAllProjects: true, silentlyReconcile: true)
    }

    /// Batch un-import: filesystem work per skill, then a single refresh.
    /// Returns the names of skills whose removal threw.
    func removeSkillsFromCatalog(_ skills: [SkillRecord]) -> [String] {
        var failed: [String] = []
        for skill in skills {
            do { try performSkillCatalogRemoval(skill) }
            catch { failed.append(skill.name) }
        }
        if skills.count > failed.count {
            refresh(includeModels: false, scanAllProjects: true, silentlyReconcile: true)
        }
        return failed
    }

    /// Resolves a duplicate skill name by keeping one canonical copy and
    /// removing all other copies. Project assignments, global defaults, and
    /// agent skill lists keyed by the skill name are intentionally preserved,
    /// because the name remains valid via the kept copy.
    func resolveSkillDuplicate(keeping keptSkill: SkillRecord, removing removedSkills: [SkillRecord]) throws {
        try SkillDuplicateResolution.removeDuplicateCopies(
            keeping: keptSkill,
            removing: removedSkills,
            canDelete: canDeleteSkill,
            delete: { [weak self] skill in
                guard let self else { return }
                let url = self.skillDeletionTargetURL(for: skill)
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                self.removeExternalSkillCatalogReferences(for: skill, deletedTarget: url)
                self.unlistSkillFromSyncedRepository(skill)
            },
            isImported: isImportedSkill,
            removeExternalPath: { [weak self] skill in
                guard let self else { return }
                let url = self.skillDeletionTargetURL(for: skill)
                self.removeExternalSkillCatalogReferences(for: skill, deletedTarget: url)
            },
            unlistFromSyncedRepository: { [weak self] skill in
                self?.unlistSkillFromSyncedRepository(skill)
            }
        )

        // Hide removed rows immediately. `removeDuplicateCopies` already
        // performed the file/catalog work; this only updates the UI.
        withAnimation(.snappy(duration: 0.18)) {
            for skill in removedSkills {
                _ = pendingDeletedSkillIDs.insert(skill.id)
            }
        }

        // Select the kept copy. Because its id is unchanged, this is stable.
        selectedSkillID = keptSkill.id
        refresh(includeModels: false, scanAllProjects: true, silentlyReconcile: true)
    }

    /// Drop `skill` from its synced repository's tracked set, if it belongs to
    /// one. When that leaves the repository with no synced skills, the whole
    /// repository is un-registered — its record is removed (so it is no longer
    /// polled for updates) and its app-managed clone is deleted.
    func unlistSkillFromSyncedRepository(_ skill: SkillRecord) {
        guard let repository = importedRepository(for: skill) else { return }
        let rootPath = skillDeletionTargetURL(for: skill).standardizedFileURL.path
        let cloneURL = URL(fileURLWithPath: repository.clonePath, isDirectory: true).standardizedFileURL

        var remaining = repository.syncedSkillRelativePaths
        remaining.removeAll { relativePath in
            let candidate = relativePath.isEmpty
                ? cloneURL.path
                : cloneURL.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL.path
            return candidate == rootPath
        }
        guard remaining != repository.syncedSkillRelativePaths else { return }

        if remaining.isEmpty {
            // Nothing left synced from this repository — fully un-register it so
            // it is no longer checked for updates, and drop its app-managed clone.
            appSettingsController.removeImportedSkillRepository(id: repository.id)
            removeSkillCollection(forRepositoryID: repository.id)
            try? FileManager.default.removeItem(at: cloneURL)
        } else {
            var updated = repository
            updated.syncedSkillRelativePaths = remaining
            appSettingsController.upsertImportedSkillRepository(updated)
            updateSkillCollection(for: updated)
            reconcileSparseCheckout(for: updated)
        }
        appSettings = appSettingsController.settings
    }

    func removeSkillCollection(forRepositoryID repositoryID: UUID) {
        guard let collection = appSettingsController.settings.skillCollections.first(where: { $0.importedRepositoryID == repositoryID }) else { return }
        appSettingsController.removeSkillCollection(id: collection.id)
        for projectPath in projectPreferencesStore.preferencesByPath.keys {
            projectPreferencesStore.setAssignedSkillCollection(collection.id, assigned: false, for: projectPath)
        }
    }

    func updateSkillCollection(for repository: ImportedSkillRepository) {
        guard var collection = appSettingsController.settings.skillCollections.first(where: { $0.importedRepositoryID == repository.id }) else { return }
        collection.skillRootPaths = Set(repository.syncedSkillRootPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        appSettingsController.upsertSkillCollection(collection)
    }

    /// Keep Git's sparse-checkout patterns aligned with Agent Deck's tracked
    /// imported-skill set. This is best-effort because the user-facing removal
    /// already succeeded once settings were updated.
    func reconcileSparseCheckout(for repository: ImportedSkillRepository) {
        let cloneURL = URL(fileURLWithPath: repository.clonePath, isDirectory: true)
        let directories = repository.syncedSkillRelativePaths.filter { !$0.isEmpty }
        Task { [skillRepositorySyncService] in
            do {
                try await skillRepositorySyncService.setSparseCheckout(directories, inCloneAt: cloneURL)
            } catch {
#if DEBUG
                NSLog("Failed to reconcile sparse checkout for imported skill repository %@: %@", repository.displayName, String(describing: error))
#endif
            }
        }
    }

    func skillIsEnabledGlobally(_ skill: SkillRecord) -> Bool {
        appSettings.defaultSkillNames.contains(skill.name)
    }

    func moveSkillToGlobalDirectory(_ skill: SkillRecord) throws {
        let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
        let sourceURL = skillMoveSourceURL(fileURL: fileURL)
        let destinationRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/skills", isDirectory: true)
            .standardizedFileURL
        let destinationURL = destinationRoot.appendingPathComponent(skill.name, isDirectory: true)

        guard !isSymbolicLink(sourceURL), !isSymbolicLink(fileURL) else {
            throw ResourceRenameError.unsupportedResource("Symlinked skills cannot be made Default safely in app. Move the real skill folder to ~/.pi/agent/skills instead.")
        }
        guard sourceURL.standardizedFileURL.path != destinationURL.standardizedFileURL.path else { return }
        try ensureGlobalSkillDestinationAvailable(destinationURL, sourceURL: sourceURL)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true, attributes: nil)

        if fileURL.lastPathComponent == "SKILL.md" {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        } else {
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false, attributes: nil)
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL.appendingPathComponent("SKILL.md"))
        }
    }

    func skillMoveSourceURL(fileURL: URL) -> URL {
        if fileURL.lastPathComponent == "SKILL.md" {
            return fileURL.deletingLastPathComponent().standardizedFileURL
        }
        return fileURL.standardizedFileURL
    }

    func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true ||
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    func ensureGlobalSkillDestinationAvailable(_ destinationURL: URL, sourceURL: URL) throws {
        let destination = destinationURL.standardizedFileURL
        let source = sourceURL.standardizedFileURL
        guard destination.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/skills", isDirectory: true).standardizedFileURL.path + "/") else {
            throw ResourceRenameError.unsafePath(destination.path)
        }
        if pathExistsOrIsSymlink(destination), destination.path != source.path {
            throw ResourceRenameError.destinationExists(destination.path)
        }
    }

    func skillIsEnabledForSelectedProject(_ skill: SkillRecord) -> Bool {
        guard let selectedProjectPath else { return false }
        return projectPreference(for: selectedProjectPath).assignedSkillNames.contains(skill.name)
    }

    func skillRecap(for project: DiscoveredProject) -> ProjectSkillRecap {
        let defaultNames = appSettings.defaultSkillNames
        let projectNames = projectPreference(for: project.path).assignedSkillNames.subtracting(defaultNames)
        let catalog = skillCatalog(forProjectPath: project.path)
        let grouped = Dictionary(grouping: catalog, by: \.name)

        func resolvedSkills(for names: Set<String>) -> ([SkillRecord], [String]) {
            var skills: [SkillRecord] = []
            var unresolved: [String] = []

            for name in names.sorted() {
                let matches = grouped[name] ?? []
                if matches.count == 1, let skill = matches.first {
                    skills.append(skill)
                } else {
                    unresolved.append(name)
                }
            }

            return (
                skills.sorted { lhs, rhs in
                    lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                },
                unresolved
            )
        }

        let defaultResult = resolvedSkills(for: defaultNames)
        let projectResult = resolvedSkills(for: projectNames)
        return ProjectSkillRecap(
            defaultSkills: defaultResult.0,
            projectSkills: projectResult.0,
            unresolvedNames: (defaultResult.1 + projectResult.1).sorted()
        )
    }

    /// MCP servers assigned to a project (global defaults + per-project), resolved
    /// against the merged `mcp.json` so the project-row summary can list them like

    func parentSkillArguments(for projectURL: URL) throws -> [String] {
        let projectPath = projectURL.standardizedFileURL.path
        let names = effectiveSkillNames(
            directNames: appSettings.defaultSkillNames.union(projectPreference(for: projectPath).assignedSkillNames),
            collectionIDs: appSettings.defaultSkillCollectionIDs.union(projectPreference(for: projectPath).assignedSkillCollectionIDs),
            catalog: skillCatalog(forProjectPath: projectPath)
        )
        return try PiSkillLaunchResolver.skillArguments(for: names, catalog: skillCatalog(forProjectPath: projectPath), missingSkillPolicy: .skip)
    }

    func agentDeckBuilderSkillArguments() -> [String] {
        globalCatalogSnapshot.skills
            .filter { $0.source.kind == .builtin }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .flatMap { ["--skill", $0.filePath] }
    }

    func skillCatalog(forProjectPath projectPath: String) -> [SkillRecord] {
        let records = globalSnapshot.skills + globalSnapshot.librarySkills
        let disabledBundled = appSettings.disabledBundledSkillNames
        var seen = Set<String>()
        return records
            .filter { !($0.source.kind == .builtin && disabledBundled.contains($0.name)) }
            .filter { seen.insert($0.id).inserted }
    }

    func skillRecords(in collection: SkillCollectionRecord, forProjectPath projectPath: String? = nil) -> [SkillRecord] {
        let catalog: [SkillRecord]
        if let projectPath {
            catalog = skillCatalog(forProjectPath: projectPath)
        } else {
            catalog = allVisibleSkillRecords
        }
        var records: [SkillRecord] = []
        var seenIDs = Set<String>()
        for skill in catalog where skillBelongsToCollection(skill, collection: collection, catalog: catalog) {
            if seenIDs.insert(skill.id).inserted { records.append(skill) }
        }
        return records.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func skillCollectionMemberIDsByCollectionID(for collections: [SkillCollectionRecord], forProjectPath projectPath: String? = nil) -> [UUID: Set<SkillRecord.ID>] {
        let catalog: [SkillRecord]
        if let projectPath {
            catalog = skillCatalog(forProjectPath: projectPath)
        } else {
            catalog = allVisibleSkillRecords
        }
        guard !collections.isEmpty, !catalog.isEmpty else {
            return Dictionary(uniqueKeysWithValues: collections.map { ($0.id, Set<SkillRecord.ID>()) })
        }

        let nameCounts = Dictionary(grouping: catalog, by: \.name).mapValues(\.count)
        let normalizedCollections = collections.map { collection in
            (
                id: collection.id,
                rootPaths: Set(collection.skillRootPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }),
                skillNames: collection.skillNames
            )
        }
        let normalizedSkills = catalog.map { skill in
            (
                id: skill.id,
                name: skill.name,
                rootPath: skillDeletionTargetURL(for: skill).path,
                filePath: URL(fileURLWithPath: skill.filePath).standardizedFileURL.path
            )
        }

        var memberIDsByCollectionID = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, Set<SkillRecord.ID>()) })
        for normalizedSkill in normalizedSkills {
            for collection in normalizedCollections {
                let isRootMatch = collection.rootPaths.contains(normalizedSkill.rootPath) || collection.rootPaths.contains(normalizedSkill.filePath)
                let isUniqueNameFallback = collection.skillNames.contains(normalizedSkill.name) && nameCounts[normalizedSkill.name] == 1
                if isRootMatch || isUniqueNameFallback {
                    memberIDsByCollectionID[collection.id, default: []].insert(normalizedSkill.id)
                }
            }
        }
        return memberIDsByCollectionID
    }

    func skillCollections(containing skill: SkillRecord) -> [SkillCollectionRecord] {
        let catalog = selectedProjectPath.map { skillCatalog(forProjectPath: $0) } ?? allVisibleSkillRecords
        return appSettings.skillCollections.filter { collection in
            skillBelongsToCollection(skill, collection: collection, catalog: catalog)
        }
    }

    func saveSkillCollection(_ collection: SkillCollectionRecord) {
        guard appSettingsController.upsertSkillCollection(collection) else { return }
        appSettings = appSettingsController.settings
        refresh(includeModels: false, scanAllProjects: true)
    }

    func removeSkillCollection(_ collection: SkillCollectionRecord) {
        guard appSettingsController.removeSkillCollection(id: collection.id) else { return }
        for projectPath in projectPreferencesStore.preferencesByPath.keys {
            projectPreferencesStore.setAssignedSkillCollection(collection.id, assigned: false, for: projectPath)
        }
        for agent in snapshot.effectiveAgents where agent.resolved.skills.contains(collection.name) {
            guard var draft = makeAgentDraft(for: agent) else { continue }
            draft.config.skills.removeAll { $0 == collection.name }
            try? agentPersistence.save(draft, original: agent, projectRoot: selectedProjectPath)
        }
        appSettings = appSettingsController.settings
        applyProjectPreferenceChanges()
        refresh(includeModels: false, scanAllProjects: true)
    }

    func skillRootPath(forCollectionMembership skill: SkillRecord) -> String {
        let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
        return fileURL.lastPathComponent == "SKILL.md"
            ? fileURL.deletingLastPathComponent().path
            : fileURL.path
    }

    func skillBelongsToCollection(_ skill: SkillRecord, collection: SkillCollectionRecord, catalog: [SkillRecord]) -> Bool {
        let rootPaths = Set(collection.skillRootPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let rootPath = skillDeletionTargetURL(for: skill).standardizedFileURL.path
        let filePath = URL(fileURLWithPath: skill.filePath).standardizedFileURL.path
        if rootPaths.contains(rootPath) || rootPaths.contains(filePath) { return true }
        guard collection.skillNames.contains(skill.name) else { return false }
        // Name fallback is only safe when the catalog has a single matching name;
        // otherwise a stale collection member would accidentally expand to every
        // duplicate and turn an unrelated duplicate into a launch blocker.
        return catalog.filter { $0.name == skill.name }.count == 1
    }

    func skillIsExcludedFromRuntime(_ skill: SkillRecord, in collection: SkillCollectionRecord, catalog: [SkillRecord]? = nil) -> Bool {
        let excludedRootPaths = Set(collection.excludedSkillRootPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let rootPath = skillDeletionTargetURL(for: skill).standardizedFileURL.path
        let filePath = URL(fileURLWithPath: skill.filePath).standardizedFileURL.path
        if excludedRootPaths.contains(rootPath) || excludedRootPaths.contains(filePath) { return true }
        guard collection.excludedSkillNames.contains(skill.name) else { return false }
        let lookupCatalog = catalog ?? (selectedProjectPath.map { skillCatalog(forProjectPath: $0) } ?? allVisibleSkillRecords)
        return lookupCatalog.filter { $0.name == skill.name }.count == 1
    }

    func skillCollectionIsEnabledGlobally(_ collection: SkillCollectionRecord) -> Bool {
        appSettings.defaultSkillCollectionIDs.contains(collection.id)
    }

    func skillCollection(_ collection: SkillCollectionRecord, isEnabledFor project: DiscoveredProject) -> Bool {
        projectPreference(for: project.path).assignedSkillCollectionIDs.contains(collection.id)
    }

    func setSkillCollection(_ collection: SkillCollectionRecord, enabled: Bool, for project: DiscoveredProject) {
        projectPreferencesStore.setAssignedSkillCollection(collection.id, assigned: enabled, for: project.path)
        applyProjectPreferenceChanges()
        reconcileSnapshotsFromPreferences()
    }

    func enableSkillCollectionGlobally(_ collection: SkillCollectionRecord) {
        guard appSettingsController.setDefaultSkillCollection(collection.id, enabled: true) else { return }
        appSettings = appSettingsController.settings
        refresh(includeModels: false, scanAllProjects: true)
    }

    func disableSkillCollectionGlobally(_ collection: SkillCollectionRecord) {
        guard appSettingsController.setDefaultSkillCollection(collection.id, enabled: false) else { return }
        appSettings = appSettingsController.settings
        refresh(includeModels: false)
    }

    func effectiveSkillNames(directNames: Set<String>, collectionIDs: Set<UUID>, catalog: [SkillRecord]) -> [String] {
        var names = directNames
        let collectionsByID = Dictionary(uniqueKeysWithValues: appSettings.skillCollections.map { ($0.id, $0) })
        for id in collectionIDs {
            guard let collection = collectionsByID[id] else { continue }
            for skill in catalog where skillBelongsToCollection(skill, collection: collection, catalog: catalog) && !skillIsExcludedFromRuntime(skill, in: collection, catalog: catalog) {
                names.insert(skill.name)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Names of the skills actually loaded into the parent session for
    /// `projectPath`: global defaults ∪ project-assigned. This is the exact set
    /// `parentSkillArguments` launches the orchestrator with — the single source
    /// of truth shared by the composer `/` browser's `isActive` flag and the
    /// session-resources popover, so neither recomputes it independently.
    func activeParentSkillNames(forProjectPath projectPath: String?, useSelectedProjectFallback: Bool = true) -> Set<String> {
        let fallback = useSelectedProjectFallback ? selectedProjectPath : nil
        let path = (projectPath ?? fallback)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        var directNames = appSettings.defaultSkillNames
        var collectionIDs = appSettings.defaultSkillCollectionIDs
        if let path {
            let preference = projectPreference(for: path)
            directNames.formUnion(preference.assignedSkillNames)
            collectionIDs.formUnion(preference.assignedSkillCollectionIDs)
        }
        let catalog = path.map { skillCatalog(forProjectPath: $0) } ?? (globalSnapshot.skills + globalSnapshot.librarySkills)
        let availableSkillNames = Set(catalog.map(\.name))
        return Set(effectiveSkillNames(directNames: directNames, collectionIDs: collectionIDs, catalog: catalog))
            .filter { availableSkillNames.contains($0) }
    }

    /// The resolved `SkillRecord`s actually available to the parent session for
    /// `projectPath` — the active names above, resolved against the same
    /// disabled-bundled-filtered catalog the launch path uses, deduped by name.
    func activeParentSkills(forProjectPath projectPath: String?) -> [SkillRecord] {
        let scopedPath = (projectPath ?? selectedProjectPath)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let activeNames = activeParentSkillNames(forProjectPath: scopedPath)
        let catalog: [SkillRecord]
        if let path = scopedPath {
            catalog = skillCatalog(forProjectPath: path)
        } else {
            var seen = Set<String>()
            catalog = (globalSnapshot.skills + globalSnapshot.librarySkills).filter { seen.insert($0.id).inserted }
        }
        var seenName = Set<String>()
        return catalog
            .filter { activeNames.contains($0.name) }
            .filter { seenName.insert($0.name).inserted }
    }

    /// Prompt-template analogue of `activeParentSkillNames`: the templates the

    func skillDeletionTargetURL(for skill: SkillRecord) -> URL {
        let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
        if fileURL.lastPathComponent == "SKILL.md" {
            return fileURL.deletingLastPathComponent()
        }
        return fileURL
    }

    func removeSkillReferences(named skillName: String) throws {
        _ = appSettingsController.setDefaultSkill(skillName, enabled: false)
        appSettings = appSettingsController.settings

        for projectPath in projectPreferencesStore.preferencesByPath.keys {
            projectPreferencesStore.setAssignedSkill(skillName, assigned: false, for: projectPath)
        }
        applyProjectPreferenceChanges()

        for agent in snapshot.effectiveAgents where agent.resolved.skills.contains(skillName) {
            guard var draft = makeAgentDraft(for: agent) else { continue }
            draft.config.skills.removeAll { $0 == skillName }
            // Persist without a per-agent refresh — `saveAgentDraft` would
            // trigger a synchronous rescan per agent. The single trailing
            // refresh(scanAllProjects:) in deleteSkill picks up every edit.
            try agentPersistence.save(draft, original: agent, projectRoot: selectedProjectPath)
        }
    }

    func removeExternalSkillCatalogReferences(for skill: SkillRecord, deletedTarget: URL) {
        let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
        let deletedTargetPath = deletedTarget.standardizedFileURL.path
        let pathsToRemove = appSettings.externalSkillPaths.filter { rawPath in
            let url = URL(fileURLWithPath: rawPath).standardizedFileURL
            return url.path == fileURL.path || url.path == deletedTargetPath
        }
        let removedPaths = Set(pathsToRemove.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let pluginReferences = Set(cachedResolvedCodexPluginSkillPaths.compactMap { reference, path in
            path == deletedTargetPath || path == fileURL.path ? reference : nil
        })
        let removedPathsChanged = appSettingsController.removeExternalSkillPaths(pathsToRemove)
        let removedPluginsChanged = appSettingsController.removeCodexPluginSkillReferences(pluginReferences)
        guard removedPathsChanged || removedPluginsChanged else { return }
        pruneSkillCollections(removingSkillName: skill.name, rootPath: deletedTargetPath, filePath: fileURL.path, extraPaths: removedPaths)
        appSettings = appSettingsController.settings
    }

    func pruneSkillCollections(removingSkillName skillName: String, rootPath: String, filePath: String, extraPaths: Set<String> = []) {
        var updatedCollections: [SkillCollectionRecord] = []
        var didChange = false
        let removalPaths = extraPaths.union([rootPath, filePath].map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        for var collection in appSettingsController.settings.skillCollections {
            let before = collection
            collection.skillNames.remove(skillName)
            collection.skillRootPaths.subtract(removalPaths)
            collection.excludedSkillNames.remove(skillName)
            collection.excludedSkillRootPaths.subtract(removalPaths)
            if collection.skillRootPaths.isEmpty && collection.skillNames.isEmpty {
                didChange = true
                continue
            }
            if collection != before { didChange = true }
            updatedCollections.append(collection)
        }
        guard didChange else { return }
        appSettingsController.replaceSkillCollections(updatedCollections)
        let known = Set(updatedCollections.map(\.id))
        for projectPath in projectPreferencesStore.preferencesByPath.keys {
            let preference = projectPreferencesStore.preference(for: projectPath)
            for id in preference.assignedSkillCollectionIDs where !known.contains(id) {
                projectPreferencesStore.setAssignedSkillCollection(id, assigned: false, for: projectPath)
            }
        }
    }

    func makeNewLibrarySkillDraft() -> NewSkillDraft {
        .init(
            name: nextAvailableSkillName(),
            description: "",
            body: "Document the skill instructions here."
        )
    }

    func newLibrarySkillPath(for name: String) -> String {
        let skillsRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/skills", isDirectory: true)
        return skillsRoot
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("SKILL.md")
            .path
    }

    func saveNewLibrarySkill(_ draft: NewSkillDraft) throws {
        let name = try validateNewSkillName(draft.name)
        let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            throw ResourceRenameError.invalidName("Description cannot be empty.")
        }

        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Document the skill instructions here."
            : draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = """
        ---
        name: \(name)
        description: \(description)
        ---

        # \(name)

        \(body)
        """

        let fileURL = URL(fileURLWithPath: newLibrarySkillPath(for: name))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Computes the path and seed content for a brand-new library skill
    /// (`~/.pi/agent/skills/<name>/SKILL.md`) without touching the disk. The
    /// folder and `SKILL.md` are written only when the user saves the editor
    /// sheet, so cancelling creates nothing — matching the agent editor, where
    /// nothing is stored until Save.
    func newLibrarySkillDraft() -> (path: String, seedContent: String) {
        let fileManager = FileManager.default
        let skillsRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/skills", isDirectory: true)
        let candidate = nextAvailableSkillName()
        let url = skillsRoot
            .appendingPathComponent(candidate, isDirectory: true)
            .appendingPathComponent("SKILL.md")
        let text = """
        ---
        name: \(candidate)
        description: Describe what this skill does and when Pi should use it.
        ---

        # \(candidate)

        Document the skill instructions here.
        """
        return (url.path, text)
    }

    func nextAvailableSkillName() -> String {
        let fileManager = FileManager.default
        let skillsRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/skills", isDirectory: true)
        var candidate = "new-skill"
        var index = 2
        while fileManager.fileExists(atPath: skillsRoot.appendingPathComponent(candidate, isDirectory: true).path) {
            candidate = "new-skill-\(index)"
            index += 1
        }
        return candidate
    }

    func validateNewSkillName(_ requestedName: String) throws -> String {
        let name = try ResourceRenameSupport.normalizedName(requestedName)
        let pattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/
        guard name.wholeMatch(of: pattern) != nil else {
            throw ResourceRenameError.invalidName("Skill name must use lowercase letters, numbers, and single hyphens only.")
        }

        let fileURL = URL(fileURLWithPath: newLibrarySkillPath(for: name))
        guard !FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path) else {
            throw ResourceRenameError.destinationExists(fileURL.deletingLastPathComponent().path)
        }
        return name
    }

    /// switches.

    func skillVisible(to agent: EffectiveAgentRecord, skill: SkillRecord) -> Bool {
        switch skill.source.kind {
        case .project, .legacyProject:
            guard let skillProject = projectName(from: skill.filePath) else { return false }
            if let agentProject = agent.projectRoot.map({ URL(fileURLWithPath: $0).lastPathComponent }) {
                return skillProject == agentProject
            }
            return false
        default:
            return true
        }
    }

    func projectName(from path: String) -> String? {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        if let piIndex = components.lastIndex(of: ".pi"), piIndex > 0 {
            return components[piIndex - 1]
        }
        if let agentsIndex = components.lastIndex(of: ".agents"), agentsIndex > 0 {
            return components[agentsIndex - 1]
        }
        return nil
    }



}
