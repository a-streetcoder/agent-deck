import Foundation

enum AppAppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }
}

enum PiAgentThinkingDisplayMode: String, Codable, CaseIterable, Identifiable {
    case full = "Show"
    case hidden = "Hidden"

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = PiAgentThinkingDisplayMode(rawValue: rawValue) ?? .full
    }
}

struct PiAgentTranscriptVisibilitySettings: Codable, Hashable {
    var showThinking: Bool = true
    var showWebActivity: Bool = true
    var showToolCalls: Bool = true
    var showErrors: Bool = true
    var showPlans: Bool = true
    var showDiffs: Bool = true

    enum CodingKeys: String, CodingKey {
        case showThinking
        case showWebActivity
        case showToolCalls
        case showErrors
        case showPlans
        case showDiffs
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showThinking = try container.decodeIfPresent(Bool.self, forKey: .showThinking) ?? true
        showWebActivity = try container.decodeIfPresent(Bool.self, forKey: .showWebActivity) ?? true
        showToolCalls = try container.decodeIfPresent(Bool.self, forKey: .showToolCalls) ?? true
        showErrors = try container.decodeIfPresent(Bool.self, forKey: .showErrors) ?? true
        showPlans = try container.decodeIfPresent(Bool.self, forKey: .showPlans) ?? true
        showDiffs = try container.decodeIfPresent(Bool.self, forKey: .showDiffs) ?? true
    }
}

struct AppSettings: Codable, Hashable {
    var appearanceMode: AppAppearanceMode = .system
    var gitHubBoardCacheLifetimeMinutes: Int = 15
    var piAgentNotificationDelayMinutes: Int = 3
    var piAgentIdleParkingEnabled: Bool = true
    var piAgentIdleParkingTimeoutMinutes: Int = 10
    var piAgentLazyTranscriptLoadingEnabled: Bool = true
    var piAgentLoadedTranscriptCacheLimit: Int = 10
    var piAgentThinkingDisplayMode: PiAgentThinkingDisplayMode = .full
    var piAgentTranscriptVisibility: PiAgentTranscriptVisibilitySettings = .init()
    var piAgentTerminalApplicationPath: String?
    var projectsRootPath: String = ProjectDiscovery.defaultRootDirectoryURL().path
    var defaultSkillsImportRootPath: String?
    var nativeSubagentsEnabledForNewSessions: Bool = true
    var showContextSmartZoneHint: Bool = false
    var autoGeneratePiAgentSessionTitles: Bool = false
    var autoUpdatePiAgentSessionTitles: Bool = false
    var piAgentTitleGenerationModelIdentifier: String?
    var piAgentGitAutomationEnabled: Bool = false
    var piAgentGitAutomationRequiresConfirmation: Bool = true
    var piAgentCommitMessageModelIdentifier: String?
    var disabledModelIdentifiers: Set<String> = []
    var openAIFastModeModelIdentifiers: Set<String> = []
    var disabledInjectedCommandIDs: Set<String> = []
    var enabledLibraryCommandIDs: Set<String> = []
    var defaultAgentNames: Set<String> = []
    var defaultSkillNames: Set<String> = []
    var externalSkillPaths: Set<String> = []
    var defaultPromptTemplateNames: Set<String> = []
    var didMigrateAgentAssignmentsFromDiscoveredFiles: Bool = false

    enum CodingKeys: String, CodingKey {
        case appearanceMode
        case gitHubBoardCacheLifetimeMinutes
        case piAgentNotificationDelayMinutes
        case piAgentIdleParkingEnabled
        case piAgentIdleParkingTimeoutMinutes
        case piAgentLazyTranscriptLoadingEnabled
        case piAgentLoadedTranscriptCacheLimit
        case piAgentThinkingDisplayMode
        case piAgentTranscriptVisibility
        case piAgentTerminalApplicationPath
        case projectsRootPath
        case defaultSkillsImportRootPath
        case nativeSubagentsEnabledForNewSessions
        case showContextSmartZoneHint
        case autoGeneratePiAgentSessionTitles
        case autoUpdatePiAgentSessionTitles
        case piAgentTitleGenerationModelIdentifier
        case piAgentGitAutomationEnabled
        case piAgentGitAutomationRequiresConfirmation
        case piAgentCommitMessageModelIdentifier
        case disabledModelIdentifiers
        case openAIFastModeModelIdentifiers
        case disabledInjectedCommandIDs
        case enabledLibraryCommandIDs
        case defaultAgentNames
        case defaultSkillNames
        case externalSkillPaths
        case defaultPromptTemplateNames
        case didMigrateAgentAssignmentsFromDiscoveredFiles
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appearanceMode = try container.decodeIfPresent(AppAppearanceMode.self, forKey: .appearanceMode) ?? .system
        gitHubBoardCacheLifetimeMinutes = try container.decodeIfPresent(Int.self, forKey: .gitHubBoardCacheLifetimeMinutes) ?? 15
        piAgentNotificationDelayMinutes = try container.decodeIfPresent(Int.self, forKey: .piAgentNotificationDelayMinutes) ?? 3
        let decodedIdleParkingTimeout = try container.decodeIfPresent(Int.self, forKey: .piAgentIdleParkingTimeoutMinutes) ?? 10
        piAgentIdleParkingEnabled = try container.decodeIfPresent(Bool.self, forKey: .piAgentIdleParkingEnabled) ?? (decodedIdleParkingTimeout > 0)
        piAgentIdleParkingTimeoutMinutes = max(decodedIdleParkingTimeout, 1)
        piAgentLazyTranscriptLoadingEnabled = try container.decodeIfPresent(Bool.self, forKey: .piAgentLazyTranscriptLoadingEnabled) ?? true
        piAgentLoadedTranscriptCacheLimit = max(try container.decodeIfPresent(Int.self, forKey: .piAgentLoadedTranscriptCacheLimit) ?? 10, 1)
        piAgentThinkingDisplayMode = (try? container.decodeIfPresent(PiAgentThinkingDisplayMode.self, forKey: .piAgentThinkingDisplayMode)) ?? .full
        piAgentTranscriptVisibility = try container.decodeIfPresent(PiAgentTranscriptVisibilitySettings.self, forKey: .piAgentTranscriptVisibility) ?? .init()
        piAgentTerminalApplicationPath = try container.decodeIfPresent(String.self, forKey: .piAgentTerminalApplicationPath)
        projectsRootPath = try container.decodeIfPresent(String.self, forKey: .projectsRootPath) ?? ProjectDiscovery.defaultRootDirectoryURL().path
        defaultSkillsImportRootPath = try container.decodeIfPresent(String.self, forKey: .defaultSkillsImportRootPath)
        nativeSubagentsEnabledForNewSessions = try container.decodeIfPresent(Bool.self, forKey: .nativeSubagentsEnabledForNewSessions) ?? true
        showContextSmartZoneHint = try container.decodeIfPresent(Bool.self, forKey: .showContextSmartZoneHint) ?? false
        autoGeneratePiAgentSessionTitles = try container.decodeIfPresent(Bool.self, forKey: .autoGeneratePiAgentSessionTitles) ?? false
        autoUpdatePiAgentSessionTitles = try container.decodeIfPresent(Bool.self, forKey: .autoUpdatePiAgentSessionTitles) ?? false
        piAgentTitleGenerationModelIdentifier = try container.decodeIfPresent(String.self, forKey: .piAgentTitleGenerationModelIdentifier)
        piAgentGitAutomationEnabled = try container.decodeIfPresent(Bool.self, forKey: .piAgentGitAutomationEnabled) ?? false
        piAgentGitAutomationRequiresConfirmation = try container.decodeIfPresent(Bool.self, forKey: .piAgentGitAutomationRequiresConfirmation) ?? true
        piAgentCommitMessageModelIdentifier = try container.decodeIfPresent(String.self, forKey: .piAgentCommitMessageModelIdentifier)
        disabledModelIdentifiers = try container.decodeIfPresent(Set<String>.self, forKey: .disabledModelIdentifiers) ?? []
        openAIFastModeModelIdentifiers = try container.decodeIfPresent(Set<String>.self, forKey: .openAIFastModeModelIdentifiers) ?? []
        disabledInjectedCommandIDs = try container.decodeIfPresent(Set<String>.self, forKey: .disabledInjectedCommandIDs) ?? []
        enabledLibraryCommandIDs = try container.decodeIfPresent(Set<String>.self, forKey: .enabledLibraryCommandIDs) ?? []
        defaultAgentNames = try container.decodeIfPresent(Set<String>.self, forKey: .defaultAgentNames) ?? []
        defaultSkillNames = try container.decodeIfPresent(Set<String>.self, forKey: .defaultSkillNames) ?? []
        externalSkillPaths = try container.decodeIfPresent(Set<String>.self, forKey: .externalSkillPaths) ?? []
        defaultPromptTemplateNames = try container.decodeIfPresent(Set<String>.self, forKey: .defaultPromptTemplateNames) ?? []
        didMigrateAgentAssignmentsFromDiscoveredFiles = try container.decodeIfPresent(Bool.self, forKey: .didMigrateAgentAssignmentsFromDiscoveredFiles) ?? false
    }
}

struct TerminalApplicationOption: Identifiable, Hashable {
    static let defaultID = "__macos_default__"

    var name: String
    var path: String?

    var id: String { path ?? Self.defaultID }
}

@MainActor
final class AppSettingsStore {
    static let shared = AppSettingsStore()

    private let defaults = UserDefaults.standard
    private let defaultsKey = "agentDeckAppSettings"

    var settings: AppSettings {
        didSet { persist() }
    }

    private init() {
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
