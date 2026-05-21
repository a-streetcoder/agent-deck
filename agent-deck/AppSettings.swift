import Foundation

struct PiAgentTranscriptVisibilitySettings: Codable, Hashable {
    var showShortcutsStrip: Bool = true
    var showThinking: Bool = false
    var showWebActivity: Bool = true
    var showToolCalls: Bool = false
    var showErrors: Bool = false
    var showPlans: Bool = true
    var showDiffs: Bool = true

    enum CodingKeys: String, CodingKey {
        case showShortcutsStrip
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
        showShortcutsStrip = try container.decodeIfPresent(Bool.self, forKey: .showShortcutsStrip) ?? true
        showThinking = try container.decodeIfPresent(Bool.self, forKey: .showThinking) ?? false
        showWebActivity = try container.decodeIfPresent(Bool.self, forKey: .showWebActivity) ?? true
        showToolCalls = try container.decodeIfPresent(Bool.self, forKey: .showToolCalls) ?? false
        showErrors = try container.decodeIfPresent(Bool.self, forKey: .showErrors) ?? false
        showPlans = try container.decodeIfPresent(Bool.self, forKey: .showPlans) ?? true
        showDiffs = try container.decodeIfPresent(Bool.self, forKey: .showDiffs) ?? true
    }
}

struct AppSettings: Codable, Hashable {
    var gitHubBoardCacheLifetimeMinutes: Int = 15
    var piAgentNotificationDelayMinutes: Int = 3
    var piAgentIdleParkingEnabled: Bool = true
    var piAgentIdleParkingTimeoutMinutes: Int = 10
    var piAgentTranscriptVisibility: PiAgentTranscriptVisibilitySettings = .init()
    var piAgentTerminalApplicationPath: String?
    var projectsRootPath: String = ProjectDiscovery.defaultRootDirectoryURL().path
    var didConfirmProjectsRootPath: Bool = false
    var defaultSkillsImportRootPath: String?
    var nativeSubagentsEnabledForNewSessions: Bool = true
    var agentMemoryEnabled: Bool = false
    var agentMemorySubagentsEnabled: Bool = true
    var agentMemoryShowTranscriptCards: Bool = true
    var agentMemoryInjectionCharacterBudget: Int = 6_000
    var agentMemoryRetentionDays: Int = 120
    var showContextSmartZoneHint: Bool = false
    var autoGeneratePiAgentSessionTitles: Bool = false
    var autoUpdatePiAgentSessionTitles: Bool = false
    var piAgentTitleGenerationModelIdentifier: String?
    var piAgentGitAutomationEnabled: Bool = false
    var piAgentGitAutomationRequiresConfirmation: Bool = true
    var piAgentCommitMessageModelIdentifier: String?
    var autoGenerateAgentAvatarPrompts: Bool = false
    var agentAvatarPromptModelIdentifier: String?
    var disabledModelIdentifiers: Set<String> = []
    var openAIFastModeModelIdentifiers: Set<String> = []
    var disabledInjectedCommandIDs: Set<String> = []
    var enabledLibraryCommandIDs: Set<String> = []
    var defaultAgentNames: Set<String> = []
    var defaultSkillNames: Set<String> = []
    var externalSkillPaths: Set<String> = []
    var importedSkillRepositories: [ImportedSkillRepository] = []
    var defaultPromptTemplateNames: Set<String> = []
    var externalPromptPaths: Set<String> = []
    var didMigrateAgentAssignmentsFromDiscoveredFiles: Bool = false

    enum CodingKeys: String, CodingKey {
        case gitHubBoardCacheLifetimeMinutes
        case piAgentNotificationDelayMinutes
        case piAgentIdleParkingEnabled
        case piAgentIdleParkingTimeoutMinutes
        case piAgentTranscriptVisibility
        case piAgentTerminalApplicationPath
        case projectsRootPath
        case didConfirmProjectsRootPath
        case defaultSkillsImportRootPath
        case nativeSubagentsEnabledForNewSessions
        case agentMemoryEnabled
        case agentMemorySubagentsEnabled
        case agentMemoryShowTranscriptCards
        case agentMemoryInjectionCharacterBudget
        case agentMemoryRetentionDays
        case showContextSmartZoneHint
        case autoGeneratePiAgentSessionTitles
        case autoUpdatePiAgentSessionTitles
        case piAgentTitleGenerationModelIdentifier
        case piAgentGitAutomationEnabled
        case piAgentGitAutomationRequiresConfirmation
        case piAgentCommitMessageModelIdentifier
        case autoGenerateAgentAvatarPrompts
        case agentAvatarPromptModelIdentifier
        case disabledModelIdentifiers
        case openAIFastModeModelIdentifiers
        case disabledInjectedCommandIDs
        case enabledLibraryCommandIDs
        case defaultAgentNames
        case defaultSkillNames
        case externalSkillPaths
        case importedSkillRepositories
        case defaultPromptTemplateNames
        case externalPromptPaths
        case didMigrateAgentAssignmentsFromDiscoveredFiles
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gitHubBoardCacheLifetimeMinutes = try container.decodeIfPresent(Int.self, forKey: .gitHubBoardCacheLifetimeMinutes) ?? 15
        piAgentNotificationDelayMinutes = try container.decodeIfPresent(Int.self, forKey: .piAgentNotificationDelayMinutes) ?? 3
        let decodedIdleParkingTimeout = try container.decodeIfPresent(Int.self, forKey: .piAgentIdleParkingTimeoutMinutes) ?? 10
        piAgentIdleParkingEnabled = try container.decodeIfPresent(Bool.self, forKey: .piAgentIdleParkingEnabled) ?? (decodedIdleParkingTimeout > 0)
        piAgentIdleParkingTimeoutMinutes = max(decodedIdleParkingTimeout, 1)
        piAgentTranscriptVisibility = try container.decodeIfPresent(PiAgentTranscriptVisibilitySettings.self, forKey: .piAgentTranscriptVisibility) ?? .init()
        piAgentTerminalApplicationPath = try container.decodeIfPresent(String.self, forKey: .piAgentTerminalApplicationPath)
        let hasStoredProjectsRootPath = container.contains(.projectsRootPath)
        projectsRootPath = try container.decodeIfPresent(String.self, forKey: .projectsRootPath) ?? ProjectDiscovery.defaultRootDirectoryURL().path
        didConfirmProjectsRootPath = try container.decodeIfPresent(Bool.self, forKey: .didConfirmProjectsRootPath) ?? hasStoredProjectsRootPath
        defaultSkillsImportRootPath = try container.decodeIfPresent(String.self, forKey: .defaultSkillsImportRootPath)
        nativeSubagentsEnabledForNewSessions = try container.decodeIfPresent(Bool.self, forKey: .nativeSubagentsEnabledForNewSessions) ?? true
        agentMemoryEnabled = try container.decodeIfPresent(Bool.self, forKey: .agentMemoryEnabled) ?? false
        agentMemorySubagentsEnabled = try container.decodeIfPresent(Bool.self, forKey: .agentMemorySubagentsEnabled) ?? true
        agentMemoryShowTranscriptCards = try container.decodeIfPresent(Bool.self, forKey: .agentMemoryShowTranscriptCards) ?? true
        agentMemoryInjectionCharacterBudget = max(try container.decodeIfPresent(Int.self, forKey: .agentMemoryInjectionCharacterBudget) ?? 6_000, 1_000)
        agentMemoryRetentionDays = max(try container.decodeIfPresent(Int.self, forKey: .agentMemoryRetentionDays) ?? 120, 1)
        showContextSmartZoneHint = try container.decodeIfPresent(Bool.self, forKey: .showContextSmartZoneHint) ?? false
        autoGeneratePiAgentSessionTitles = try container.decodeIfPresent(Bool.self, forKey: .autoGeneratePiAgentSessionTitles) ?? false
        autoUpdatePiAgentSessionTitles = try container.decodeIfPresent(Bool.self, forKey: .autoUpdatePiAgentSessionTitles) ?? false
        piAgentTitleGenerationModelIdentifier = try container.decodeIfPresent(String.self, forKey: .piAgentTitleGenerationModelIdentifier)
        piAgentGitAutomationEnabled = try container.decodeIfPresent(Bool.self, forKey: .piAgentGitAutomationEnabled) ?? false
        piAgentGitAutomationRequiresConfirmation = try container.decodeIfPresent(Bool.self, forKey: .piAgentGitAutomationRequiresConfirmation) ?? true
        piAgentCommitMessageModelIdentifier = try container.decodeIfPresent(String.self, forKey: .piAgentCommitMessageModelIdentifier)
        autoGenerateAgentAvatarPrompts = try container.decodeIfPresent(Bool.self, forKey: .autoGenerateAgentAvatarPrompts) ?? false
        agentAvatarPromptModelIdentifier = try container.decodeIfPresent(String.self, forKey: .agentAvatarPromptModelIdentifier)
        disabledModelIdentifiers = try container.decodeIfPresent(Set<String>.self, forKey: .disabledModelIdentifiers) ?? []
        openAIFastModeModelIdentifiers = try container.decodeIfPresent(Set<String>.self, forKey: .openAIFastModeModelIdentifiers) ?? []
        disabledInjectedCommandIDs = try container.decodeIfPresent(Set<String>.self, forKey: .disabledInjectedCommandIDs) ?? []
        enabledLibraryCommandIDs = try container.decodeIfPresent(Set<String>.self, forKey: .enabledLibraryCommandIDs) ?? []
        defaultAgentNames = try container.decodeIfPresent(Set<String>.self, forKey: .defaultAgentNames) ?? []
        defaultSkillNames = try container.decodeIfPresent(Set<String>.self, forKey: .defaultSkillNames) ?? []
        externalSkillPaths = try container.decodeIfPresent(Set<String>.self, forKey: .externalSkillPaths) ?? []
        importedSkillRepositories = try container.decodeIfPresent([ImportedSkillRepository].self, forKey: .importedSkillRepositories) ?? []
        defaultPromptTemplateNames = try container.decodeIfPresent(Set<String>.self, forKey: .defaultPromptTemplateNames) ?? []
        externalPromptPaths = try container.decodeIfPresent(Set<String>.self, forKey: .externalPromptPaths) ?? []
        didMigrateAgentAssignmentsFromDiscoveredFiles = try container.decodeIfPresent(Bool.self, forKey: .didMigrateAgentAssignmentsFromDiscoveredFiles) ?? false
    }
}

struct TerminalApplicationOption: Identifiable, Hashable {
    static let defaultID = "__macos_default__"

    var name: String
    var path: String?

    var id: String { path ?? Self.defaultID }
}

/// Terminal applications Agent Deck can reliably open a fresh window in and have it
/// run a prepared script. Terminal and iTerm are driven through AppleScript; Ghostty,
/// kitty, Alacritty and WezTerm expose a command-line flag that runs a given command
/// in a new window. Terminals without any such mechanism — notably Warp and Hyper —
/// are intentionally unsupported: there is no dependable way to make them run our
/// Pi session/update script.
enum SupportedTerminal: CaseIterable {
    case appleTerminal
    case iTerm
    case ghostty
    case kitty
    case alacritty
    case wezTerm

    /// Lowercased `.app` bundle file name, used to recognise a chosen application.
    var bundleName: String {
        switch self {
        case .appleTerminal: return "terminal.app"
        case .iTerm: return "iterm.app"
        case .ghostty: return "ghostty.app"
        case .kitty: return "kitty.app"
        case .alacritty: return "alacritty.app"
        case .wezTerm: return "wezterm.app"
        }
    }

    /// For the CLI-driven terminals, the executable inside `Contents/MacOS` and the
    /// argument(s) that must precede the `/bin/zsh <script>` invocation. `nil` for the
    /// AppleScript-driven terminals (Terminal, iTerm).
    var commandLineLauncher: (executable: String, leadingArguments: [String])? {
        switch self {
        case .appleTerminal, .iTerm: return nil
        case .ghostty: return ("ghostty", ["-e"])
        case .kitty: return ("kitty", [])
        case .alacritty: return ("alacritty", ["-e"])
        case .wezTerm: return ("wezterm", ["start", "--"])
        }
    }

    /// Human-readable list of every supported terminal, for help text and warnings.
    static let displayList = "Terminal, iTerm, Ghostty, kitty, Alacritty, and WezTerm"

    /// Resolves the terminal identified by an application bundle path, if it is one
    /// Agent Deck supports.
    init?(appPath: String) {
        let name = URL(fileURLWithPath: appPath).lastPathComponent.lowercased()
        guard let match = Self.allCases.first(where: { $0.bundleName == name }) else { return nil }
        self = match
    }
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
