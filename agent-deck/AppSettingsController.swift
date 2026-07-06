import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppSettingsController {
    private let store: AppSettingsStore
    private(set) var settings: AppSettings

    @MainActor
    init() {
        let sharedStore = AppSettingsStore.shared
        self.store = sharedStore
        self.settings = sharedStore.settings
        discardUnsupportedTerminalSelection()
        discardUnknownThemeSelection()
    }

    @MainActor
    init(store: AppSettingsStore) {
        self.store = store
        self.settings = store.settings
        discardUnsupportedTerminalSelection()
        discardUnknownThemeSelection()
    }

    /// Earlier builds allowed selecting any terminal app, including ones Agent Deck
    /// cannot drive (Warp, Hyper). Drop such a stale selection so terminal actions
    /// fall back to macOS Terminal instead of silently doing nothing.
    private func discardUnsupportedTerminalSelection() {
        guard let path = settings.piAgentTerminalApplicationPath, !path.isEmpty,
              SupportedTerminal(appPath: path) == nil else { return }
        settings.piAgentTerminalApplicationPath = nil
        persist()
    }

    /// Reset to the Default theme if the stored selection points at a theme that
    /// no longer exists — corrupted data, or a custom theme deleted elsewhere.
    private func discardUnknownThemeSelection() {
        let knownIDs = Set(allThemes.map(\.id))
        guard !knownIDs.contains(settings.selectedThemeID) else { return }
        settings.selectedThemeID = Theme.defaultTheme.id
        persist()
    }

    /// Fixed issue-board cache lifetime. Was user-configurable; nobody needs
    /// to tune it, and Refresh bypasses the cache anyway.
    var gitHubBoardCacheLifetime: TimeInterval { 15 * 60 }

    var piAgentNotificationDelayMinutes: Int {
        max(settings.piAgentNotificationDelayMinutes, 1)
    }

    var isPiAgentIdleParkingEnabled: Bool {
        settings.piAgentIdleParkingEnabled
    }

    var piAgentIdleParkingTimeoutMinutes: Int {
        max(settings.piAgentIdleParkingTimeoutMinutes, 1)
    }

    /// Every configured projects-root entry, standardized and de-duplicated.
    /// Empty if the user has not added any roots.
    var configuredProjectsRootURLs: [URL] {
        var seen: Set<String> = []
        return settings.projectsRootPaths.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let standardized = URL(fileURLWithPath: trimmed).standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return nil }
            return standardized
        }
    }

    var configuredProjectsRootPaths: [String] {
        configuredProjectsRootURLs.map(\.path)
    }

    /// The "primary" root — first configured entry, or the default suggested
    /// folder when the user has not added any. Callers that need a single URL
    /// (e.g. "where do new sessions land?") should use this.
    var primaryProjectsRootURL: URL {
        configuredProjectsRootURLs.first ?? ProjectDiscovery.defaultRootDirectoryURL()
    }

    var primaryProjectsRootPath: String {
        primaryProjectsRootURL.path
    }

    var suggestedProjectsRootURL: URL? {
        ProjectDiscovery.suggestedRootDirectoryURL()
    }

    var hasConfirmedProjectsRootPaths: Bool {
        settings.didConfirmProjectsRootPaths
    }

    var piAgentTerminalApplicationDisplayName: String {
        guard let path = settings.piAgentTerminalApplicationPath, !path.isEmpty else {
            return "macOS default"
        }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    var piAgentTerminalApplicationSelectionID: String {
        settings.piAgentTerminalApplicationPath ?? TerminalApplicationOption.defaultID
    }

    var piAgentExtensionLoadingMode: PiAgentExtensionLoadingMode {
        settings.piAgentExtensionLoadingMode
    }

    var piAgentLaunchPreview: String {
        settings.piAgentExtensionLoadingMode.parentSessionLaunchPreview
    }

    /// Runs filesystem discovery — call OFF the main thread (e.g. in `Task.detached`),
    /// never from a SwiftUI body.
    func discoveredPiExtensions(projectRoot: URL?) -> [PiExtensionCandidate] {
        PiExtensionDiscoveryService().discover(projectRoot: projectRoot)
    }

    func isPiExtensionEnabled(_ candidate: PiExtensionCandidate) -> Bool {
        !settings.disabledPiExtensionIDs.contains(candidate.id)
    }

    var piAgentTerminalApplicationOptions: [TerminalApplicationOption] {
        var options = [TerminalApplicationOption(name: "macOS Default", path: nil)]
        // Only terminals Agent Deck can reliably drive (see `SupportedTerminal`).
        let candidates = [
            "/System/Applications/Utilities/Terminal.app",
            "/Applications/Utilities/Terminal.app",
            "/Applications/iTerm.app",
            "/Applications/Ghostty.app",
            "/Applications/kitty.app",
            "/Applications/Alacritty.app",
            "/Applications/WezTerm.app"
        ]

        var seen = Set(options.map(\.id))
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            let option = TerminalApplicationOption(name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, path: path)
            guard seen.insert(option.id).inserted else { continue }
            options.append(option)
        }

        // A previously chosen terminal in a non-standard location stays selectable, but
        // only if it is one we support.
        if let selectedPath = settings.piAgentTerminalApplicationPath,
           !seen.contains(selectedPath),
           SupportedTerminal(appPath: selectedPath) != nil {
            options.append(TerminalApplicationOption(name: URL(fileURLWithPath: selectedPath).deletingPathExtension().lastPathComponent, path: selectedPath))
        }

        return options
    }

    var areSubagentsEnabledForNewSessions: Bool {
        settings.nativeSubagentsEnabledForNewSessions
    }

    var nativeSubagentDelegationPolicy: NativeSubagentDelegationPolicy {
        settings.nativeSubagentDelegationPolicy
    }

    var isAgentMemoryEnabled: Bool {
        settings.agentMemoryEnabled
    }

    var disabledProviders: Set<String> {
        settings.disabledProviders
    }

    var disabledModelIdentifiers: Set<String> {
        settings.disabledModelIdentifiers
    }

    var openAIFastModeModelIdentifiers: Set<String> {
        settings.openAIFastModeModelIdentifiers
    }

    var disabledInjectedCommandIDs: Set<String> {
        settings.disabledInjectedCommandIDs
    }

    var defaultSkillNames: Set<String> {
        settings.defaultSkillNames
    }

    var defaultSkillCollectionIDs: Set<UUID> {
        settings.defaultSkillCollectionIDs
    }

    var skillCollections: [SkillCollectionRecord] {
        settings.skillCollections
    }

    var externalSkillPaths: Set<String> {
        settings.externalSkillPaths
    }

    var defaultPromptTemplateNames: Set<String> {
        settings.defaultPromptTemplateNames
    }

    var externalPromptPaths: Set<String> {
        settings.externalPromptPaths
    }

    var shouldShowContextSmartZoneHint: Bool {
        settings.showContextSmartZoneHint
    }

    var shouldAutoGeneratePiAgentSessionTitles: Bool {
        settings.autoGeneratePiAgentSessionTitles
    }

    var shouldAutoUpdatePiAgentSessionTitles: Bool {
        settings.autoUpdatePiAgentSessionTitles
    }

    var piAgentTitleGenerationModelIdentifier: String? {
        settings.piAgentTitleGenerationModelIdentifier
    }

    var piAgentCommitMessageModelIdentifier: String? {
        settings.piAgentCommitMessageModelIdentifier
    }

    var shouldAutoGenerateAgentAvatarPrompts: Bool {
        settings.autoGenerateAgentAvatarPrompts
    }

    var agentAvatarPromptModelIdentifier: String? {
        settings.agentAvatarPromptModelIdentifier
    }

    var skillDescriptionModelIdentifier: String? {
        settings.skillDescriptionModelIdentifier
    }

    @discardableResult
    func setPiAgentNotificationDelayMinutes(_ minutes: Int) -> Bool {
        let normalizedMinutes = max(minutes, 1)
        guard settings.piAgentNotificationDelayMinutes != normalizedMinutes else { return false }
        settings.piAgentNotificationDelayMinutes = normalizedMinutes
        persist()
        return true
    }

    @discardableResult
    func setPiAgentIdleParkingEnabled(_ isEnabled: Bool) -> Bool {
        guard settings.piAgentIdleParkingEnabled != isEnabled else { return false }
        settings.piAgentIdleParkingEnabled = isEnabled
        persist()
        return true
    }

    @discardableResult
    func setPiAgentIdleParkingTimeoutMinutes(_ minutes: Int) -> Bool {
        let normalizedMinutes = max(minutes, 1)
        guard settings.piAgentIdleParkingTimeoutMinutes != normalizedMinutes else { return false }
        settings.piAgentIdleParkingTimeoutMinutes = normalizedMinutes
        persist()
        return true
    }

    /// Opens an NSOpenPanel and either *appends* (Settings) or *replaces*
    /// (first-run onboarding) the configured list with the chosen folder(s).
    /// Returns true if anything changed.
    @discardableResult
    func chooseProjectsRootDirectory(replacingExisting: Bool = false) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = replacingExisting ? "Choose Projects Folder" : "Add Projects Folder"
        panel.message = "Choose one or more parent folders that contain your projects. Do not choose individual project repositories."
        panel.directoryURL = suggestedProjectsRootURL ?? primaryProjectsRootURL

        guard panel.runModal() == .OK else { return false }
        let chosenPaths = panel.urls.map(\.path)
        guard !chosenPaths.isEmpty else { return false }
        return replacingExisting
            ? setProjectsRootPaths(chosenPaths)
            : addProjectsRootPaths(chosenPaths)
    }

    /// Adds (or, if `replacingExisting`, sets) the configured list to the
    /// system-suggested folder (`~/Documents/GitHub`, `~/Code`, …).
    @discardableResult
    func useSuggestedProjectsRootDirectory(replacingExisting: Bool = false) -> Bool {
        guard let suggestedProjectsRootURL else { return false }
        return replacingExisting
            ? setProjectsRootPaths([suggestedProjectsRootURL.path])
            : addProjectsRootPaths([suggestedProjectsRootURL.path])
    }

    /// Replace the entire configured list with the supplied paths, normalized
    /// and de-duplicated. Used by first-run onboarding where appending would
    /// surprise the user.
    @discardableResult
    func setProjectsRootPaths(_ paths: [String]) -> Bool {
        var seen = Set<String>()
        let normalized = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { seen.insert($0).inserted }
        guard !normalized.isEmpty else { return false }
        let confirmedChanged = !settings.didConfirmProjectsRootPaths
        guard settings.projectsRootPaths != normalized || confirmedChanged else { return false }
        settings.projectsRootPaths = normalized
        settings.didConfirmProjectsRootPaths = true
        persist()
        return true
    }

    /// Append one or more paths to the projects-root list. Trimmed, standardized,
    /// and de-duplicated against existing entries. Marks the list as confirmed.
    @discardableResult
    func addProjectsRootPaths(_ paths: [String]) -> Bool {
        let normalizedNewPaths = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard !normalizedNewPaths.isEmpty else { return false }

        var existing = settings.projectsRootPaths
        let existingSet = Set(existing)
        var added = false
        for path in normalizedNewPaths where !existingSet.contains(path) {
            existing.append(path)
            added = true
        }
        let confirmedChanged = !settings.didConfirmProjectsRootPaths
        guard added || confirmedChanged else { return false }
        settings.projectsRootPaths = existing
        settings.didConfirmProjectsRootPaths = true
        persist()
        return true
    }

    @discardableResult
    func removeProjectsRootPath(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL.path
        let updated = settings.projectsRootPaths.filter { stored in
            URL(fileURLWithPath: stored).standardizedFileURL.path != normalized
        }
        guard updated.count != settings.projectsRootPaths.count else { return false }
        settings.projectsRootPaths = updated
        persist()
        return true
    }

    @discardableResult
    func replaceProjectsRootPath(at index: Int, with path: String) -> Bool {
        guard settings.projectsRootPaths.indices.contains(index) else { return false }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let normalized = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        guard settings.projectsRootPaths[index] != normalized else { return false }

        var updated = settings.projectsRootPaths
        // Drop any duplicate of the new path elsewhere in the list, then place
        // it at the original row so the user-visible order is preserved.
        for otherIndex in updated.indices.reversed() where otherIndex != index {
            let existingNormalized = URL(fileURLWithPath: updated[otherIndex]).standardizedFileURL.path
            if existingNormalized == normalized {
                updated.remove(at: otherIndex)
            }
        }
        let targetIndex = min(index, max(updated.count - 1, 0))
        if updated.indices.contains(targetIndex) {
            updated[targetIndex] = normalized
        } else {
            updated.append(normalized)
        }
        settings.projectsRootPaths = updated
        settings.didConfirmProjectsRootPaths = true
        persist()
        return true
    }

    @discardableResult
    func resetProjectsRootPathsToDefault() -> Bool {
        let defaultPath = ProjectDiscovery.defaultRootDirectoryURL().path
        guard settings.projectsRootPaths != [defaultPath] || !settings.didConfirmProjectsRootPaths else { return false }
        settings.projectsRootPaths = [defaultPath]
        settings.didConfirmProjectsRootPaths = true
        persist()
        return true
    }

    func setPiAgentTerminalApplicationSelection(_ selectionID: String) {
        setPiAgentTerminalApplicationPath(selectionID == TerminalApplicationOption.defaultID ? nil : selectionID)
    }

    @discardableResult
    func choosePiAgentTerminalApplication() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.prompt = "Choose App"
        panel.message = "Choose the terminal app \(AppBrand.displayName) should use when resuming a Pi session in the CLI."
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        guard panel.runModal() == .OK, let url = panel.url else { return false }

        guard SupportedTerminal(appPath: url.path) != nil else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Unsupported terminal app"
            alert.informativeText = "\(AppBrand.displayName) can only run Pi sessions in \(SupportedTerminal.displayList). Other terminals provide no reliable way to open a new window and run a command."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
        return setPiAgentTerminalApplicationPath(url.path)
    }

    @discardableResult
    func setPiAgentTerminalApplicationPath(_ path: String?) -> Bool {
        let normalizedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedPath = normalizedPath?.isEmpty == false ? normalizedPath : nil
        guard settings.piAgentTerminalApplicationPath != storedPath else { return false }
        settings.piAgentTerminalApplicationPath = storedPath
        persist()
        return true
    }

    @discardableResult
    func resetPiAgentTerminalApplicationToDefault() -> Bool {
        setPiAgentTerminalApplicationPath(nil)
    }

    @discardableResult
    func setPiAgentExtensionLoadingMode(_ mode: PiAgentExtensionLoadingMode) -> Bool {
        guard settings.piAgentExtensionLoadingMode != mode else { return false }
        settings.piAgentExtensionLoadingMode = mode
        persist()
        return true
    }

    @discardableResult
    func setPiExtension(_ candidate: PiExtensionCandidate, enabled: Bool) -> Bool {
        var disabledIDs = settings.disabledPiExtensionIDs
        if enabled {
            disabledIDs.remove(candidate.id)
        } else {
            disabledIDs.insert(candidate.id)
        }
        guard disabledIDs != settings.disabledPiExtensionIDs else { return false }
        settings.disabledPiExtensionIDs = disabledIDs
        persist()
        return true
    }

    @discardableResult
    func setAllPiExtensions(_ candidates: [PiExtensionCandidate], enabled: Bool) -> Bool {
        guard !candidates.isEmpty else { return false }
        var disabledIDs = settings.disabledPiExtensionIDs
        for candidate in candidates {
            if enabled {
                disabledIDs.remove(candidate.id)
            } else {
                disabledIDs.insert(candidate.id)
            }
        }
        guard disabledIDs != settings.disabledPiExtensionIDs else { return false }
        settings.disabledPiExtensionIDs = disabledIDs
        persist()
        return true
    }

    /// Drops deselection state for extensions that are no longer discovered, so a
    /// re-appearing extension defaults to enabled. Pass the freshly discovered list.
    @discardableResult
    func prunePiExtensionSelection(to candidates: [PiExtensionCandidate]) -> Bool {
        let validIDs = Set(candidates.map(\.id))
        let pruned = settings.disabledPiExtensionIDs.intersection(validIDs)
        guard pruned != settings.disabledPiExtensionIDs else { return false }
        settings.disabledPiExtensionIDs = pruned
        persist()
        return true
    }

    @discardableResult
    func togglePiAgentThinkingBlocksVisibility() -> Bool {
        setPiAgentTranscriptVisibility(\.showThinking, to: !settings.piAgentTranscriptVisibility.showThinking)
    }

    @discardableResult
    func setDefaultAgent(_ agentName: String, enabled: Bool) -> Bool {
        var names = settings.defaultAgentNames
        if enabled {
            names.insert(agentName)
        } else {
            names.remove(agentName)
        }
        guard names != settings.defaultAgentNames else { return false }
        settings.defaultAgentNames = names
        persist()
        return true
    }

    @discardableResult
    func renameDefaultAgent(from oldName: String, to newName: String) -> Bool {
        guard oldName != newName, settings.defaultAgentNames.contains(oldName) else { return false }
        var names = settings.defaultAgentNames
        names.remove(oldName)
        names.insert(newName)
        settings.defaultAgentNames = names
        persist()
        return true
    }

    @discardableResult
    func markAgentAssignmentsMigratedFromDiscoveredFiles() -> Bool {
        guard settings.didMigrateAgentAssignmentsFromDiscoveredFiles == false else { return false }
        settings.didMigrateAgentAssignmentsFromDiscoveredFiles = true
        persist()
        return true
    }

    @discardableResult
    func setDefaultSkill(_ skillName: String, enabled: Bool) -> Bool {
        var names = settings.defaultSkillNames
        if enabled {
            names.insert(skillName)
        } else {
            names.remove(skillName)
        }
        guard names != settings.defaultSkillNames else { return false }
        settings.defaultSkillNames = names
        persist()
        return true
    }

    @discardableResult
    func renameDefaultSkill(from oldName: String, to newName: String) -> Bool {
        guard oldName != newName, settings.defaultSkillNames.contains(oldName) else { return false }
        var names = settings.defaultSkillNames
        names.remove(oldName)
        names.insert(newName)
        settings.defaultSkillNames = names
        persist()
        return true
    }

    @discardableResult
    func setDefaultSkillCollection(_ collectionID: UUID, enabled: Bool) -> Bool {
        var ids = settings.defaultSkillCollectionIDs
        if enabled {
            ids.insert(collectionID)
        } else {
            ids.remove(collectionID)
        }
        guard ids != settings.defaultSkillCollectionIDs else { return false }
        settings.defaultSkillCollectionIDs = ids
        persist()
        return true
    }

    @discardableResult
    func upsertSkillCollection(_ collection: SkillCollectionRecord) -> Bool {
        var collections = settings.skillCollections
        if let index = collections.firstIndex(where: { $0.id == collection.id }) {
            guard collections[index] != collection else { return false }
            collections[index] = collection
        } else {
            collections.append(collection)
        }
        settings.skillCollections = collections.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist()
        return true
    }

    @discardableResult
    func removeSkillCollection(id: UUID) -> Bool {
        let updated = settings.skillCollections.filter { $0.id != id }
        guard updated.count != settings.skillCollections.count else { return false }
        settings.skillCollections = updated
        settings.defaultSkillCollectionIDs.remove(id)
        persist()
        return true
    }

    @discardableResult
    func replaceSkillCollections(_ collections: [SkillCollectionRecord]) -> Bool {
        guard collections != settings.skillCollections else { return false }
        settings.skillCollections = collections.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let known = Set(settings.skillCollections.map(\.id))
        settings.defaultSkillCollectionIDs.formIntersection(known)
        persist()
        return true
    }

    @discardableResult
    func addExternalSkillPaths(_ paths: [String]) -> Bool {
        let normalizedPaths = paths
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { !$0.isEmpty }
        guard !normalizedPaths.isEmpty else { return false }
        var existingPaths = settings.externalSkillPaths
        for path in normalizedPaths {
            existingPaths.insert(path)
        }
        guard existingPaths != settings.externalSkillPaths else { return false }
        settings.externalSkillPaths = existingPaths
        persist()
        return true
    }

    @discardableResult
    func removeExternalSkillPaths(_ paths: Set<String>) -> Bool {
        let normalizedPaths = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        guard !normalizedPaths.isEmpty else { return false }
        let updatedPaths = settings.externalSkillPaths.subtracting(normalizedPaths)
        guard updatedPaths != settings.externalSkillPaths else { return false }
        settings.externalSkillPaths = updatedPaths
        persist()
        return true
    }

    @discardableResult
    func replaceExternalSkillPath(from oldPath: String, to newPath: String) -> Bool {
        let normalizedOldPath = URL(fileURLWithPath: oldPath).standardizedFileURL.path
        let normalizedNewPath = URL(fileURLWithPath: newPath).standardizedFileURL.path
        guard normalizedOldPath != normalizedNewPath, settings.externalSkillPaths.contains(normalizedOldPath) else { return false }
        var paths = settings.externalSkillPaths
        paths.remove(normalizedOldPath)
        paths.insert(normalizedNewPath)
        settings.externalSkillPaths = paths
        persist()
        return true
    }

    var importedSkillRepositories: [ImportedSkillRepository] {
        settings.importedSkillRepositories
    }

    /// Insert a synced skill repository, or replace an existing record that
    /// shares the same `id` or clone path (a re-import of the same repo).
    @discardableResult
    func upsertImportedSkillRepository(_ repository: ImportedSkillRepository) -> Bool {
        var repositories = settings.importedSkillRepositories
        repositories.removeAll { $0.id == repository.id || $0.clonePath == repository.clonePath }
        repositories.append(repository)
        settings.importedSkillRepositories = repositories
        persist()
        return true
    }

    @discardableResult
    func removeImportedSkillRepository(id: UUID) -> Bool {
        let updated = settings.importedSkillRepositories.filter { $0.id != id }
        guard updated.count != settings.importedSkillRepositories.count else { return false }
        settings.importedSkillRepositories = updated
        persist()
        return true
    }

    @discardableResult
    func addExternalPromptPaths(_ paths: [String]) -> Bool {
        let normalizedPaths = paths
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { !$0.isEmpty }
        guard !normalizedPaths.isEmpty else { return false }
        var existingPaths = settings.externalPromptPaths
        for path in normalizedPaths {
            existingPaths.insert(path)
        }
        guard existingPaths != settings.externalPromptPaths else { return false }
        settings.externalPromptPaths = existingPaths
        persist()
        return true
    }

    @discardableResult
    func removeExternalPromptPaths(_ paths: Set<String>) -> Bool {
        let normalizedPaths = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        guard !normalizedPaths.isEmpty else { return false }
        let updatedPaths = settings.externalPromptPaths.subtracting(normalizedPaths)
        guard updatedPaths != settings.externalPromptPaths else { return false }
        settings.externalPromptPaths = updatedPaths
        persist()
        return true
    }

    @discardableResult
    func replaceExternalPromptPath(from oldPath: String, to newPath: String) -> Bool {
        let normalizedOldPath = URL(fileURLWithPath: oldPath).standardizedFileURL.path
        let normalizedNewPath = URL(fileURLWithPath: newPath).standardizedFileURL.path
        guard normalizedOldPath != normalizedNewPath, settings.externalPromptPaths.contains(normalizedOldPath) else { return false }
        var paths = settings.externalPromptPaths
        paths.remove(normalizedOldPath)
        paths.insert(normalizedNewPath)
        settings.externalPromptPaths = paths
        persist()
        return true
    }

    @discardableResult
    func setDefaultPromptTemplate(_ promptName: String, enabled: Bool) -> Bool {
        var names = settings.defaultPromptTemplateNames
        if enabled {
            names.insert(promptName)
        } else {
            names.remove(promptName)
        }
        guard names != settings.defaultPromptTemplateNames else { return false }
        settings.defaultPromptTemplateNames = names
        persist()
        return true
    }

    @discardableResult
    func setBundledPromptDisabled(_ promptName: String, isDisabled: Bool) -> Bool {
        var names = settings.disabledBundledPromptNames
        if isDisabled {
            names.insert(promptName)
        } else {
            names.remove(promptName)
        }
        guard names != settings.disabledBundledPromptNames else { return false }
        settings.disabledBundledPromptNames = names
        persist()
        return true
    }

    @discardableResult
    func setBundledSkillDisabled(_ skillName: String, isDisabled: Bool) -> Bool {
        var names = settings.disabledBundledSkillNames
        if isDisabled {
            names.insert(skillName)
        } else {
            names.remove(skillName)
        }
        guard names != settings.disabledBundledSkillNames else { return false }
        settings.disabledBundledSkillNames = names
        persist()
        return true
    }

    @discardableResult
    func renameDefaultPromptTemplate(from oldName: String, to newName: String) -> Bool {
        guard oldName != newName, settings.defaultPromptTemplateNames.contains(oldName) else { return false }
        var names = settings.defaultPromptTemplateNames
        names.remove(oldName)
        names.insert(newName)
        settings.defaultPromptTemplateNames = names
        persist()
        return true
    }

    @discardableResult
    func setShowContextSmartZoneHint(_ isEnabled: Bool) -> Bool {
        guard settings.showContextSmartZoneHint != isEnabled else { return false }
        settings.showContextSmartZoneHint = isEnabled
        persist()
        return true
    }

    @discardableResult
    func setAutoGeneratePiAgentSessionTitles(_ isEnabled: Bool) -> Bool {
        guard settings.autoGeneratePiAgentSessionTitles != isEnabled else { return false }
        settings.autoGeneratePiAgentSessionTitles = isEnabled
        if !isEnabled {
            settings.autoUpdatePiAgentSessionTitles = false
        }
        persist()
        return true
    }

    @discardableResult
    func setAutoUpdatePiAgentSessionTitles(_ isEnabled: Bool) -> Bool {
        let stored = isEnabled && settings.autoGeneratePiAgentSessionTitles
        guard settings.autoUpdatePiAgentSessionTitles != stored else { return false }
        settings.autoUpdatePiAgentSessionTitles = stored
        persist()
        return true
    }

    @discardableResult
    func setPiAgentTitleGenerationModelIdentifier(_ identifier: String?) -> Bool {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = trimmed?.isEmpty == false ? trimmed : nil
        guard settings.piAgentTitleGenerationModelIdentifier != stored else { return false }
        settings.piAgentTitleGenerationModelIdentifier = stored
        persist()
        return true
    }

    @discardableResult
    func setPiAgentGitAutomationEnabled(_ isEnabled: Bool) -> Bool {
        guard settings.piAgentGitAutomationEnabled != isEnabled else { return false }
        settings.piAgentGitAutomationEnabled = isEnabled
        persist()
        return true
    }

    @discardableResult
    func setPiAgentGitAutomationRequiresConfirmation(_ isEnabled: Bool) -> Bool {
        guard settings.piAgentGitAutomationRequiresConfirmation != isEnabled else { return false }
        settings.piAgentGitAutomationRequiresConfirmation = isEnabled
        persist()
        return true
    }

    @discardableResult
    func setPiAgentCommitMessageModelIdentifier(_ identifier: String?) -> Bool {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = trimmed?.isEmpty == false ? trimmed : nil
        guard settings.piAgentCommitMessageModelIdentifier != stored else { return false }
        settings.piAgentCommitMessageModelIdentifier = stored
        persist()
        return true
    }

    @discardableResult
    func setPiAgentSessionsUseWorktree(_ isEnabled: Bool) -> Bool {
        guard settings.piAgentSessionsUseWorktree != isEnabled else { return false }
        settings.piAgentSessionsUseWorktree = isEnabled
        persist()
        return true
    }

    @discardableResult
    func setPiAgentSessionsKeepWorktreeAfterMerge(_ isEnabled: Bool) -> Bool {
        guard settings.piAgentSessionsKeepWorktreeAfterMerge != isEnabled else { return false }
        settings.piAgentSessionsKeepWorktreeAfterMerge = isEnabled
        persist()
        return true
    }

    @discardableResult
    func setPiAgentAutoUpdateEnabled(_ isEnabled: Bool) -> Bool {
        guard settings.piAgentAutoUpdateEnabled != isEnabled else { return false }
        settings.piAgentAutoUpdateEnabled = isEnabled
        persist()
        return true
    }

    @discardableResult
    func markLoopsOpenedFromSidebar() -> Bool {
        guard !settings.didOpenLoopsFromSidebar else { return false }
        settings.didOpenLoopsFromSidebar = true
        persist()
        return true
    }

    @discardableResult
    func setAutoGenerateAgentAvatarPrompts(_ isEnabled: Bool) -> Bool {
        guard settings.autoGenerateAgentAvatarPrompts != isEnabled else { return false }
        settings.autoGenerateAgentAvatarPrompts = isEnabled
        persist()
        return true
    }

    @discardableResult
    func setAgentAvatarPromptModelIdentifier(_ identifier: String?) -> Bool {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = trimmed?.isEmpty == false ? trimmed : nil
        guard settings.agentAvatarPromptModelIdentifier != stored else { return false }
        settings.agentAvatarPromptModelIdentifier = stored
        persist()
        return true
    }

    @discardableResult
    func setSkillDescriptionModelIdentifier(_ identifier: String?) -> Bool {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = trimmed?.isEmpty == false ? trimmed : nil
        guard settings.skillDescriptionModelIdentifier != stored else { return false }
        settings.skillDescriptionModelIdentifier = stored
        persist()
        return true
    }

    @discardableResult
    func setPiAgentTranscriptVisibility(_ keyPath: WritableKeyPath<PiAgentTranscriptVisibilitySettings, Bool>, to value: Bool) -> Bool {
        guard settings.piAgentTranscriptVisibility[keyPath: keyPath] != value else { return false }
        settings.piAgentTranscriptVisibility[keyPath: keyPath] = value
        persist()
        return true
    }

    @discardableResult
    func setSubagentsEnabledForNewSessions(_ isEnabled: Bool) -> Bool {
        guard settings.nativeSubagentsEnabledForNewSessions != isEnabled else { return false }
        settings.nativeSubagentsEnabledForNewSessions = isEnabled
        persist()
        return true
    }

    @discardableResult
    func setNativeSubagentDelegationPolicy(_ policy: NativeSubagentDelegationPolicy) -> Bool {
        guard settings.nativeSubagentDelegationPolicy != policy else { return false }
        settings.nativeSubagentDelegationPolicy = policy
        persist()
        return true
    }

    @discardableResult
    func setAgentMemoryEnabled(_ isEnabled: Bool) -> Bool {
        guard settings.agentMemoryEnabled != isEnabled else { return false }
        settings.agentMemoryEnabled = isEnabled
        persist()
        return true
    }

    @discardableResult
    func setAgentMemorySubagentsEnabled(_ isEnabled: Bool) -> Bool {
        guard settings.agentMemorySubagentsEnabled != isEnabled else { return false }
        settings.agentMemorySubagentsEnabled = isEnabled
        persist()
        return true
    }

    @discardableResult
    func setAgentMemoryShowTranscriptCards(_ isEnabled: Bool) -> Bool {
        guard settings.agentMemoryShowTranscriptCards != isEnabled else { return false }
        settings.agentMemoryShowTranscriptCards = isEnabled
        persist()
        return true
    }

    @discardableResult
    func setAgentMemoryInjectionCharacterBudget(_ budget: Int) -> Bool {
        let normalized = min(max(budget, 1_000), 20_000)
        guard settings.agentMemoryInjectionCharacterBudget != normalized else { return false }
        settings.agentMemoryInjectionCharacterBudget = normalized
        persist()
        return true
    }

    @discardableResult
    func toggleSubagentsForNewSessions() -> Bool {
        setSubagentsEnabledForNewSessions(!areSubagentsEnabledForNewSessions)
    }

    @discardableResult
    func setModelEnabled(identifier: String, isEnabled: Bool) -> Bool {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        var disabled = settings.disabledModelIdentifiers
        let changed: Bool
        if isEnabled {
            changed = disabled.remove(normalized) != nil
        } else {
            changed = disabled.insert(normalized).inserted
        }
        guard changed else { return false }
        settings.disabledModelIdentifiers = disabled
        persist()
        return true
    }

    @discardableResult
    func enableAllModels() -> Bool {
        guard !settings.disabledModelIdentifiers.isEmpty else { return false }
        settings.disabledModelIdentifiers = []
        persist()
        return true
    }

    @discardableResult
    func setProviderEnabled(_ provider: String, isEnabled: Bool) -> Bool {
        let normalized = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        var disabledProviders = settings.disabledProviders
        let changed: Bool
        if isEnabled {
            changed = disabledProviders.remove(normalized) != nil
        } else {
            changed = disabledProviders.insert(normalized).inserted
        }
        guard changed else { return false }
        settings.disabledProviders = disabledProviders
        persist()
        return true
    }

    @discardableResult
    func setOpenAIFastMode(identifier: String, isEnabled: Bool) -> Bool {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        var identifiers = settings.openAIFastModeModelIdentifiers
        let changed: Bool
        if isEnabled {
            changed = identifiers.insert(normalized).inserted
        } else {
            changed = identifiers.remove(normalized) != nil
        }
        guard changed else { return false }
        settings.openAIFastModeModelIdentifiers = identifiers
        persist()
        return true
    }

    @discardableResult
    func setInjectedCommandEnabled(_ command: PiInjectedCommand, isEnabled: Bool) -> Bool {
        switch command.source {
        case .builtIn:
            var disabled = settings.disabledInjectedCommandIDs
            let changed = isEnabled ? (disabled.remove(command.id) != nil) : disabled.insert(command.id).inserted
            guard changed else { return false }
            settings.disabledInjectedCommandIDs = disabled
        case .library:
            var enabled = settings.enabledLibraryCommandIDs
            let changed = isEnabled ? enabled.insert(command.id).inserted : (enabled.remove(command.id) != nil)
            guard changed else { return false }
            settings.enabledLibraryCommandIDs = enabled
        }
        persist()
        return true
    }

    // MARK: - Color themes

    /// Built-in presets followed by the user's custom themes.
    var allThemes: [Theme] {
        Theme.builtInThemes + settings.customThemes
    }

    /// The currently selected theme, falling back to Default if the stored id
    /// resolves to nothing.
    var resolvedActiveTheme: Theme {
        allThemes.first { $0.id == settings.selectedThemeID } ?? .defaultTheme
    }

    @discardableResult
    func setPiAgentMarkdownHighlightingEnabled(_ isEnabled: Bool) -> Bool {
        guard settings.piAgentMarkdownHighlightingEnabled != isEnabled else { return false }
        settings.piAgentMarkdownHighlightingEnabled = isEnabled
        persist()
        return true
    }

    @discardableResult
    func selectTheme(id: UUID) -> Bool {
        let target = allThemes.contains(where: { $0.id == id }) ? id : Theme.defaultTheme.id
        guard settings.selectedThemeID != target else { return false }
        settings.selectedThemeID = target
        persist()
        return true
    }

    @discardableResult
    func addCustomTheme(_ theme: Theme) -> Bool {
        var stored = theme
        stored.isBuiltIn = false
        settings.customThemes.append(stored)
        persist()
        return true
    }

    @discardableResult
    func updateCustomTheme(_ theme: Theme) -> Bool {
        guard let index = settings.customThemes.firstIndex(where: { $0.id == theme.id }) else { return false }
        var stored = theme
        stored.isBuiltIn = false
        guard settings.customThemes[index] != stored else { return false }
        settings.customThemes[index] = stored
        persist()
        return true
    }

    @discardableResult
    func deleteCustomTheme(id: UUID) -> Bool {
        guard let index = settings.customThemes.firstIndex(where: { $0.id == id }) else { return false }
        settings.customThemes.remove(at: index)
        if settings.selectedThemeID == id {
            settings.selectedThemeID = Theme.defaultTheme.id
        }
        persist()
        return true
    }

    // MARK: - App icon

    var selectedAppIcon: AppIconChoice {
        AppIconChoice.choice(forStoredName: settings.selectedAppIconName)
    }

    @discardableResult
    func selectAppIcon(_ choice: AppIconChoice) -> Bool {
        let stored: String? = (choice == .default) ? nil : choice.rawValue
        guard settings.selectedAppIconName != stored else { return false }
        settings.selectedAppIconName = stored
        persist()
        return true
    }

    /// Copies any theme — preset or custom — into a new editable custom theme.
    /// This is how a preset gets customized.
    func duplicateTheme(id: UUID) -> Theme? {
        guard let source = allThemes.first(where: { $0.id == id }) else { return nil }
        var copy = source
        copy.id = UUID()
        copy.isBuiltIn = false
        copy.name = "\(source.name) Copy"
        settings.customThemes.append(copy)
        persist()
        return copy
    }

    func setMCPEnabled(_ enabled: Bool) {
        guard settings.mcpEnabled != enabled else { return }
        settings.mcpEnabled = enabled
        persist()
    }

    func setDefaultMcpServer(_ name: String, enabled: Bool) {
        if enabled { settings.defaultMcpServerNames.insert(name) }
        else { settings.defaultMcpServerNames.remove(name) }
        persist()
    }

    private func persist() {
        store.settings = settings
    }
}
