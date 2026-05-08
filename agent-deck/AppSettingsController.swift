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

    var gitHubBoardCacheLifetimeMinutes: Int {
        max(settings.gitHubBoardCacheLifetimeMinutes, 1)
    }

    var piAgentNotificationDelayMinutes: Int {
        max(settings.piAgentNotificationDelayMinutes, 1)
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

    var disabledModelIdentifiers: Set<String> {
        settings.disabledModelIdentifiers
    }

    var enabledExtensionPaths: Set<String> {
        settings.enabledExtensionPaths
    }

    var shouldShowContextSmartZoneHint: Bool {
        settings.showContextSmartZoneHint
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
        panel.message = "Choose the folder Agent Deck should scan for projects and use for projectless Pi Agent sessions."
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
        panel.message = "Choose the default folder Agent Deck should open when importing skills."
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
        panel.message = "Choose the terminal app Agent Deck should use when resuming a Pi session in the CLI."
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
    func setPiAgentThinkingDisplayMode(_ mode: PiAgentThinkingDisplayMode) -> Bool {
        guard settings.piAgentThinkingDisplayMode != mode else { return false }
        settings.piAgentThinkingDisplayMode = mode
        persist()
        return true
    }

    @discardableResult
    func togglePiAgentThinkingBlocksVisibility() -> Bool {
        setPiAgentTranscriptVisibility(\.showThinking, to: !settings.piAgentTranscriptVisibility.showThinking)
    }

    @discardableResult
    func setShowContextSmartZoneHint(_ isEnabled: Bool) -> Bool {
        guard settings.showContextSmartZoneHint != isEnabled else { return false }
        settings.showContextSmartZoneHint = isEnabled
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
    func setExtensionEnabled(path: String, isEnabled: Bool) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        var enabled = settings.enabledExtensionPaths
        let changed: Bool
        if isEnabled {
            changed = enabled.insert(normalized).inserted
        } else {
            changed = enabled.remove(normalized) != nil
        }
        guard changed else { return false }
        settings.enabledExtensionPaths = enabled
        persist()
        return true
    }

    private func persist() {
        store.settings = settings
    }
}
