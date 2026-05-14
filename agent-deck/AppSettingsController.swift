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
    }

    @MainActor
    init(store: AppSettingsStore) {
        self.store = store
        self.settings = store.settings
    }

    var gitHubBoardCacheLifetime: TimeInterval {
        TimeInterval(gitHubBoardCacheLifetimeMinutes * 60)
    }

    var appearanceMode: AppAppearanceMode {
        settings.appearanceMode
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

    var isPiAgentLazyTranscriptLoadingEnabled: Bool {
        settings.piAgentLazyTranscriptLoadingEnabled
    }

    var piAgentLoadedTranscriptCacheLimit: Int {
        max(settings.piAgentLoadedTranscriptCacheLimit, 1)
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
        let candidates = [
            "/System/Applications/Utilities/Terminal.app",
            "/Applications/Utilities/Terminal.app",
            "/Applications/iTerm.app",
            "/Applications/Warp.app",
            "/Applications/Ghostty.app",
            "/Applications/WezTerm.app",
            "/Applications/Alacritty.app",
            "/Applications/kitty.app",
            "/Applications/Hyper.app"
        ]

        var seen = Set(options.map(\.id))
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            let option = TerminalApplicationOption(name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, path: path)
            guard seen.insert(option.id).inserted else { continue }
            options.append(option)
        }

        if let selectedPath = settings.piAgentTerminalApplicationPath,
           !seen.contains(selectedPath) {
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

    @discardableResult
    func setAppearanceMode(_ mode: AppAppearanceMode) -> Bool {
        guard settings.appearanceMode != mode else { return false }
        settings.appearanceMode = mode
        persist()
        return true
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
    func setPiAgentLazyTranscriptLoadingEnabled(_ isEnabled: Bool) -> Bool {
        guard settings.piAgentLazyTranscriptLoadingEnabled != isEnabled else { return false }
        settings.piAgentLazyTranscriptLoadingEnabled = isEnabled
        persist()
        return true
    }

    @discardableResult
    func setPiAgentLoadedTranscriptCacheLimit(_ count: Int) -> Bool {
        let normalizedCount = max(count, 1)
        guard settings.piAgentLoadedTranscriptCacheLimit != normalizedCount else { return false }
        settings.piAgentLoadedTranscriptCacheLimit = normalizedCount
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
        panel.prompt = "Choose Folder"
        panel.message = "Choose the folder \(AppBrand.displayName) should scan for projects and use for projectless Pi Agent sessions."
        panel.directoryURL = configuredProjectsRootURL

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return setProjectsRootPath(url.path)
    }

    @discardableResult
    func setProjectsRootPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = trimmed.isEmpty
            ? ProjectDiscovery.defaultRootDirectoryURL().path
            : URL(fileURLWithPath: trimmed).standardizedFileURL.path
        guard settings.projectsRootPath != normalizedPath else { return false }
        settings.projectsRootPath = normalizedPath
        persist()
        return true
    }

    @discardableResult
    func resetProjectsRootPathToDefault() -> Bool {
        setProjectsRootPath(ProjectDiscovery.defaultRootDirectoryURL().path)
    }

    @discardableResult
    func chooseDefaultSkillsImportDirectory(startingAt url: URL) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.message = "Choose the default folder \(AppBrand.displayName) should open when importing skills."
        panel.directoryURL = url

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return setDefaultSkillsImportRootPath(url.path)
    }

    @discardableResult
    func setDefaultSkillsImportRootPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed).standardizedFileURL.path
        guard settings.defaultSkillsImportRootPath != normalizedPath else { return false }
        settings.defaultSkillsImportRootPath = normalizedPath
        persist()
        return true
    }

    @discardableResult
    func resetDefaultSkillsImportRootPath() -> Bool {
        guard settings.defaultSkillsImportRootPath != nil else { return false }
        settings.defaultSkillsImportRootPath = nil
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

    private func persist() {
        store.settings = settings
    }
}
