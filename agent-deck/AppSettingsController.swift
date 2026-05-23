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

    var gitHubBoardCacheLifetime: TimeInterval {
        TimeInterval(gitHubBoardCacheLifetimeMinutes * 60)
    }

    var gitHubBoardCacheLifetimeMinutes: Int {
        max(settings.gitHubBoardCacheLifetimeMinutes, 1)
    }

    var piAgentNotificationDelayMinutes: Int {
        max(settings.piAgentNotificationDelayMinutes, 1)
    }

    var isPiAgentIdleParkingEnabled: Bool {
        settings.piAgentIdleParkingEnabled
    }

    var piAgentIdleParkingTimeoutMinutes: Int {
        max(settings.piAgentIdleParkingTimeoutMinutes, 1)
    }

    var configuredProjectsRootURL: URL {
        let trimmed = settings.projectsRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = ProjectDiscovery.defaultRootDirectoryURL()
        guard !trimmed.isEmpty else { return fallback }
        return URL(fileURLWithPath: trimmed).standardizedFileURL
    }

    var configuredProjectsRootPath: String {
        configuredProjectsRootURL.path
    }

    var suggestedProjectsRootURL: URL? {
        ProjectDiscovery.suggestedRootDirectoryURL()
    }

    var hasConfirmedProjectsRootPath: Bool {
        settings.didConfirmProjectsRootPath
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

    var isAgentMemoryEnabled: Bool {
        settings.agentMemoryEnabled
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

    @discardableResult
    func setGitHubBoardCacheLifetimeMinutes(_ minutes: Int) -> Bool {
        let normalizedMinutes = max(minutes, 1)
        guard settings.gitHubBoardCacheLifetimeMinutes != normalizedMinutes else { return false }
        settings.gitHubBoardCacheLifetimeMinutes = normalizedMinutes
        persist()
        return true
    }

    @discardableResult
    func chooseProjectsRootDirectory() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Projects Folder"
        panel.message = "Choose the parent folder that contains your projects. Do not choose a single project repository."
        panel.directoryURL = suggestedProjectsRootURL ?? configuredProjectsRootURL

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return setProjectsRootPath(url.path)
    }

    @discardableResult
    func useSuggestedProjectsRootDirectory() -> Bool {
        guard let suggestedProjectsRootURL else { return false }
        return setProjectsRootPath(suggestedProjectsRootURL.path)
    }

    @discardableResult
    func setProjectsRootPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = trimmed.isEmpty
            ? ProjectDiscovery.defaultRootDirectoryURL().path
            : URL(fileURLWithPath: trimmed).standardizedFileURL.path
        guard settings.projectsRootPath != normalizedPath || !settings.didConfirmProjectsRootPath else { return false }
        settings.projectsRootPath = normalizedPath
        settings.didConfirmProjectsRootPath = true
        persist()
        return true
    }

    @discardableResult
    func resetProjectsRootPathToDefault() -> Bool {
        setProjectsRootPath(ProjectDiscovery.defaultRootDirectoryURL().path)
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

    private func persist() {
        store.settings = settings
    }
}
