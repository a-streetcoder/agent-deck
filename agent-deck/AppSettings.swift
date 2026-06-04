import Foundation

struct PiAgentTranscriptVisibilitySettings: Codable, Hashable {
    var showShortcutsStrip: Bool = true
    var showThinking: Bool = true
    var showWebActivity: Bool = true
    var showToolCalls: Bool = true
    var showErrors: Bool = true
    var showFinalSystemPrompt: Bool = true
    var showPlans: Bool = true
    var showDiffs: Bool = true
    var showMemoryCards: Bool = true

    enum CodingKeys: String, CodingKey {
        case showShortcutsStrip
        case showThinking
        case showWebActivity
        case showToolCalls
        case showErrors
        case showFinalSystemPrompt
        case showPlans
        case showDiffs
        case showMemoryCards
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showShortcutsStrip = try container.decodeIfPresent(Bool.self, forKey: .showShortcutsStrip) ?? true
        showThinking = try container.decodeIfPresent(Bool.self, forKey: .showThinking) ?? true
        showWebActivity = try container.decodeIfPresent(Bool.self, forKey: .showWebActivity) ?? true
        showToolCalls = try container.decodeIfPresent(Bool.self, forKey: .showToolCalls) ?? true
        showErrors = try container.decodeIfPresent(Bool.self, forKey: .showErrors) ?? true
        showFinalSystemPrompt = try container.decodeIfPresent(Bool.self, forKey: .showFinalSystemPrompt) ?? true
        showPlans = try container.decodeIfPresent(Bool.self, forKey: .showPlans) ?? true
        showDiffs = try container.decodeIfPresent(Bool.self, forKey: .showDiffs) ?? true
        showMemoryCards = try container.decodeIfPresent(Bool.self, forKey: .showMemoryCards) ?? true
    }
}

enum NativeSubagentDelegationPolicy: String, Codable, CaseIterable, Hashable, Identifiable {
    case light
    case balanced
    case strict

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: return "Light"
        case .balanced: return "Balanced"
        case .strict: return "Strict"
        }
    }

    var settingsDescription: String {
        switch self {
        case .light:
            return "Use Deck agents when they clearly improve the result; the parent may handle straightforward work directly."
        case .balanced:
            return "Delegate substantive specialist work by default, but let the parent handle trivial low-risk tasks."
        case .strict:
            return "Delegate any substantive work when a matching Deck agent exists; the parent focuses on orchestration and synthesis."
        }
    }

    var promptInstructions: String {
        switch self {
        case .light:
            return """
            - Act primarily as the coordinator for Deck agents when delegation would clearly improve the result.
            - Use `managed_subagent` for separable specialist work, large investigations, parallel research, or tasks where an available agent is clearly a better fit.
            - You may do straightforward implementation, inspection, explanation, and small fixes yourself when delegation would add unnecessary overhead.
            """
        case .balanced:
            return """
            - Act primarily as the orchestrator: clarify, plan, delegate, supervise, update the visible plan, and synthesize results.
            - Delegate substantive implementation, investigation, planning, or review work to a relevant Deck agent by default; work directly only for trivial, low-risk one-off changes where delegation would add unnecessary overhead.
            - Use `managed_subagent` for bounded specialist work; include `reads` when known. Choose the available agent whose routing guidance best matches the task and expected outcome.
            """
        case .strict:
            return """
            - Act primarily as the orchestrator: clarify, plan, delegate, supervise, update the visible plan, and synthesize results.
            - For any substantive task, if an available Deck agent could reasonably perform it, delegate it with `managed_subagent`.
            - Do not keep implementation, investigation, planning, or review work in the parent merely because you can do it yourself. Work directly only for trivial conversational replies, direct user clarification, plan/status updates, synthesis of Deck agent results, or when no listed Deck agent fits.
            """
        }
    }
}

enum PiAgentExtensionLoadingMode: String, Codable, CaseIterable, Hashable, Identifiable {
    case agentDeckManaged = "agentDeckManaged"
    case piDefaultsAndAgentDeck = "piDefaultsAndAgentDeck"
    case customSelectionAndAgentDeck = "customSelectionAndAgentDeck"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .agentDeckManaged:
            return "Agent Deck managed"
        case .piDefaultsAndAgentDeck:
            return "Pi defaults + Agent Deck"
        case .customSelectionAndAgentDeck:
            return "Custom selection + Agent Deck"
        }
    }

    var settingsDescription: String {
        switch self {
        case .agentDeckManaged:
            return "Disable Pi's ambient extension discovery and load only Agent Deck's required bridge extensions plus explicitly selected Deck command extensions."
        case .piDefaultsAndAgentDeck:
            return "Let Pi load your normal configured extensions, while Agent Deck still adds its required bridge extensions for app features."
        case .customSelectionAndAgentDeck:
            return "Disable ambient discovery, then explicitly load only checked Pi extensions plus Agent Deck's required bridge extensions."
        }
    }

    var disablesAmbientPiExtensions: Bool {
        switch self {
        case .agentDeckManaged, .customSelectionAndAgentDeck:
            return true
        case .piDefaultsAndAgentDeck:
            return false
        }
    }

    var usesCustomPiExtensionSelection: Bool {
        self == .customSelectionAndAgentDeck
    }

    var ambientPiExtensionArguments: [String] {
        disablesAmbientPiExtensions ? ["--no-extensions"] : []
    }

    var parentSessionAmbientExtensionArguments: [String] {
        ambientPiExtensionArguments
    }

    var launchSummary: String {
        switch self {
        case .agentDeckManaged:
            return "pi --mode rpc --no-extensions …"
        case .piDefaultsAndAgentDeck:
            return "pi --mode rpc …"
        case .customSelectionAndAgentDeck:
            return "pi --mode rpc --no-extensions --extension <checked-pi-extension> …"
        }
    }

    var extensionDiscoverySummary: String {
        switch self {
        case .agentDeckManaged:
            return "Pi extension discovery is disabled. Agent Deck loads only its required bridges plus explicitly configured Deck extensions."
        case .piDefaultsAndAgentDeck:
            return "Pi extension discovery is enabled. Your normal Pi extensions load in addition to Agent Deck’s required bridges."
        case .customSelectionAndAgentDeck:
            return "Pi extension discovery is disabled. Agent Deck loads checked Pi extensions explicitly, then adds its required bridges."
        }
    }

    var parentSessionLaunchPreview: String {
        switch self {
        case .agentDeckManaged:
            return "Parent session: pi --mode rpc --no-extensions --extension <agent-deck-bridge.ts> …\nNative subagent: pi --mode rpc --no-extensions --extension <agent-extension.ts> --extension <agent-deck-bridge.ts> …\nAutomation helper: pi --mode rpc --no-session --no-extensions --no-tools …"
        case .piDefaultsAndAgentDeck:
            return "Parent session: pi --mode rpc --extension <agent-deck-bridge.ts> …\nNative subagent: pi --mode rpc --extension <agent-extension.ts> --extension <agent-deck-bridge.ts> …\nAutomation helper: pi --mode rpc --no-session --no-tools …"
        case .customSelectionAndAgentDeck:
            return "Parent session: pi --mode rpc --no-extensions --extension <checked-pi-extension> --extension <agent-deck-bridge.ts> …\nNative subagent: pi --mode rpc --no-extensions --extension <checked-pi-extension> --extension <agent-extension.ts> --extension <agent-deck-bridge.ts> …\nAutomation helper: pi --mode rpc --no-session --no-extensions --extension <checked-pi-extension> --no-tools …"
        }
    }
}

struct AppSettings: Codable, Hashable {
    var gitHubBoardCacheLifetimeMinutes: Int = 15
    var piAgentNotificationDelayMinutes: Int = 3
    var piAgentIdleParkingEnabled: Bool = true
    var piAgentIdleParkingTimeoutMinutes: Int = 10
    var piAgentTranscriptVisibility: PiAgentTranscriptVisibilitySettings = .init()
    var piAgentTerminalApplicationPath: String?
    var piAgentExtensionLoadingMode: PiAgentExtensionLoadingMode = .agentDeckManaged
    /// Stable candidate IDs disabled in Agent Deck's custom Pi extension mode.
    /// New/discovered extensions default to enabled until the user unchecks them.
    var disabledPiExtensionIDs: Set<String> = []
    var projectsRootPaths: [String] = [ProjectDiscovery.defaultRootDirectoryURL().path]
    var didConfirmProjectsRootPaths: Bool = false
    var nativeSubagentsEnabledForNewSessions: Bool = true
    var nativeSubagentDelegationPolicy: NativeSubagentDelegationPolicy = .balanced
    var agentMemoryEnabled: Bool = false
    var agentMemorySubagentsEnabled: Bool = true
    var agentMemoryShowTranscriptCards: Bool = true
    var agentMemoryInjectionCharacterBudget: Int = 6_000
    var agentMemoryRetentionDays: Int = 120
    var showContextSmartZoneHint: Bool = false
    var autoGeneratePiAgentSessionTitles: Bool = FoundationModelAutomationService.isAvailable()
    var autoUpdatePiAgentSessionTitles: Bool = FoundationModelAutomationService.isAvailable()
    var piAgentTitleGenerationModelIdentifier: String? = FoundationModelAutomationService.isAvailable() ? FoundationModelAutomationService.identifier : nil
    var piAgentGitAutomationEnabled: Bool = false
    var piAgentGitAutomationRequiresConfirmation: Bool = true
    var piAgentCommitMessageModelIdentifier: String?
    var piAgentSessionsUseWorktree: Bool = false
    var piAgentSessionsKeepWorktreeAfterMerge: Bool = true
    var autoGenerateAgentAvatarPrompts: Bool = false
    var agentAvatarPromptModelIdentifier: String?
    var skillDescriptionModelIdentifier: String?
    var disabledProviders: Set<String> = []
    var disabledModelIdentifiers: Set<String> = []
    var openAIFastModeModelIdentifiers: Set<String> = []
    var disabledInjectedCommandIDs: Set<String> = []
    var enabledLibraryCommandIDs: Set<String> = []
    var defaultAgentNames: Set<String> = []
    var defaultSkillNames: Set<String> = []
    var externalSkillPaths: Set<String> = []
    var importedSkillRepositories: [ImportedSkillRepository] = []
    var defaultPromptTemplateNames: Set<String> = []
    var disabledBundledPromptNames: Set<String> = []
    var disabledBundledSkillNames: Set<String> = []
    var externalPromptPaths: Set<String> = []
    var didMigrateAgentAssignmentsFromDiscoveredFiles: Bool = false
    var selectedThemeID: UUID = Theme.defaultTheme.id
    var customThemes: [Theme] = []
    /// Asset-catalog name of the user-chosen Dock icon. `nil` = bundle default.
    var selectedAppIconName: String?

    enum CodingKeys: String, CodingKey {
        case gitHubBoardCacheLifetimeMinutes
        case piAgentNotificationDelayMinutes
        case piAgentIdleParkingEnabled
        case piAgentIdleParkingTimeoutMinutes
        case piAgentTranscriptVisibility
        case piAgentTerminalApplicationPath
        case piAgentExtensionLoadingMode
        case disabledPiExtensionIDs
        case projectsRootPaths
        case didConfirmProjectsRootPaths
        case nativeSubagentsEnabledForNewSessions
        case nativeSubagentDelegationPolicy
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
        case piAgentSessionsUseWorktree
        case piAgentSessionsKeepWorktreeAfterMerge
        case autoGenerateAgentAvatarPrompts
        case agentAvatarPromptModelIdentifier
        case skillDescriptionModelIdentifier
        case disabledProviders
        case disabledModelIdentifiers
        case openAIFastModeModelIdentifiers
        case disabledInjectedCommandIDs
        case enabledLibraryCommandIDs
        case defaultAgentNames
        case defaultSkillNames
        case externalSkillPaths
        case importedSkillRepositories
        case defaultPromptTemplateNames
        case disabledBundledPromptNames
        case disabledBundledSkillNames
        case externalPromptPaths
        case didMigrateAgentAssignmentsFromDiscoveredFiles
        case selectedThemeID
        case customThemes
        case selectedAppIconName
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
        piAgentExtensionLoadingMode = (try? container.decodeIfPresent(PiAgentExtensionLoadingMode.self, forKey: .piAgentExtensionLoadingMode)) ?? .agentDeckManaged
        disabledPiExtensionIDs = try container.decodeIfPresent(Set<String>.self, forKey: .disabledPiExtensionIDs) ?? []
        let hasStoredProjectsRootPaths = container.contains(.projectsRootPaths)
        projectsRootPaths = try container.decodeIfPresent([String].self, forKey: .projectsRootPaths) ?? [ProjectDiscovery.defaultRootDirectoryURL().path]
        didConfirmProjectsRootPaths = try container.decodeIfPresent(Bool.self, forKey: .didConfirmProjectsRootPaths) ?? hasStoredProjectsRootPaths
        nativeSubagentsEnabledForNewSessions = try container.decodeIfPresent(Bool.self, forKey: .nativeSubagentsEnabledForNewSessions) ?? true
        nativeSubagentDelegationPolicy = try container.decodeIfPresent(NativeSubagentDelegationPolicy.self, forKey: .nativeSubagentDelegationPolicy) ?? .balanced
        agentMemoryEnabled = try container.decodeIfPresent(Bool.self, forKey: .agentMemoryEnabled) ?? false
        agentMemorySubagentsEnabled = try container.decodeIfPresent(Bool.self, forKey: .agentMemorySubagentsEnabled) ?? true
        agentMemoryShowTranscriptCards = try container.decodeIfPresent(Bool.self, forKey: .agentMemoryShowTranscriptCards) ?? true
        agentMemoryInjectionCharacterBudget = max(try container.decodeIfPresent(Int.self, forKey: .agentMemoryInjectionCharacterBudget) ?? 6_000, 1_000)
        agentMemoryRetentionDays = max(try container.decodeIfPresent(Int.self, forKey: .agentMemoryRetentionDays) ?? 120, 1)
        showContextSmartZoneHint = try container.decodeIfPresent(Bool.self, forKey: .showContextSmartZoneHint) ?? false
        let foundationModelAvailable = FoundationModelAutomationService.isAvailable()
        autoGeneratePiAgentSessionTitles = try container.decodeIfPresent(Bool.self, forKey: .autoGeneratePiAgentSessionTitles) ?? foundationModelAvailable
        autoUpdatePiAgentSessionTitles = try container.decodeIfPresent(Bool.self, forKey: .autoUpdatePiAgentSessionTitles) ?? foundationModelAvailable
        piAgentTitleGenerationModelIdentifier = try container.decodeIfPresent(String.self, forKey: .piAgentTitleGenerationModelIdentifier)
            ?? (foundationModelAvailable ? FoundationModelAutomationService.identifier : nil)
        piAgentGitAutomationEnabled = try container.decodeIfPresent(Bool.self, forKey: .piAgentGitAutomationEnabled) ?? false
        piAgentGitAutomationRequiresConfirmation = try container.decodeIfPresent(Bool.self, forKey: .piAgentGitAutomationRequiresConfirmation) ?? true
        piAgentCommitMessageModelIdentifier = try container.decodeIfPresent(String.self, forKey: .piAgentCommitMessageModelIdentifier)
        piAgentSessionsUseWorktree = try container.decodeIfPresent(Bool.self, forKey: .piAgentSessionsUseWorktree) ?? false
        piAgentSessionsKeepWorktreeAfterMerge = try container.decodeIfPresent(Bool.self, forKey: .piAgentSessionsKeepWorktreeAfterMerge) ?? true
        autoGenerateAgentAvatarPrompts = try container.decodeIfPresent(Bool.self, forKey: .autoGenerateAgentAvatarPrompts) ?? false
        agentAvatarPromptModelIdentifier = try container.decodeIfPresent(String.self, forKey: .agentAvatarPromptModelIdentifier)
        skillDescriptionModelIdentifier = try container.decodeIfPresent(String.self, forKey: .skillDescriptionModelIdentifier)
        disabledProviders = try container.decodeIfPresent(Set<String>.self, forKey: .disabledProviders) ?? []
        disabledModelIdentifiers = try container.decodeIfPresent(Set<String>.self, forKey: .disabledModelIdentifiers) ?? []
        openAIFastModeModelIdentifiers = try container.decodeIfPresent(Set<String>.self, forKey: .openAIFastModeModelIdentifiers) ?? []
        disabledInjectedCommandIDs = try container.decodeIfPresent(Set<String>.self, forKey: .disabledInjectedCommandIDs) ?? []
        enabledLibraryCommandIDs = try container.decodeIfPresent(Set<String>.self, forKey: .enabledLibraryCommandIDs) ?? []
        defaultAgentNames = try container.decodeIfPresent(Set<String>.self, forKey: .defaultAgentNames) ?? []
        defaultSkillNames = try container.decodeIfPresent(Set<String>.self, forKey: .defaultSkillNames) ?? []
        externalSkillPaths = try container.decodeIfPresent(Set<String>.self, forKey: .externalSkillPaths) ?? []
        importedSkillRepositories = try container.decodeIfPresent([ImportedSkillRepository].self, forKey: .importedSkillRepositories) ?? []
        defaultPromptTemplateNames = try container.decodeIfPresent(Set<String>.self, forKey: .defaultPromptTemplateNames) ?? []
        disabledBundledPromptNames = try container.decodeIfPresent(Set<String>.self, forKey: .disabledBundledPromptNames) ?? []
        disabledBundledSkillNames = try container.decodeIfPresent(Set<String>.self, forKey: .disabledBundledSkillNames) ?? []
        externalPromptPaths = try container.decodeIfPresent(Set<String>.self, forKey: .externalPromptPaths) ?? []
        didMigrateAgentAssignmentsFromDiscoveredFiles = try container.decodeIfPresent(Bool.self, forKey: .didMigrateAgentAssignmentsFromDiscoveredFiles) ?? false
        selectedThemeID = try container.decodeIfPresent(UUID.self, forKey: .selectedThemeID) ?? Theme.defaultTheme.id
        customThemes = try container.decodeIfPresent([Theme].self, forKey: .customThemes) ?? []
        selectedAppIconName = try container.decodeIfPresent(String.self, forKey: .selectedAppIconName)
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
        didSet { schedulePersist() }
    }

    /// Coalesces rapid settings mutations (theme picker scrubbing, model
    /// toggles) into a single encode + UserDefaults write per debounce
    /// window. Encode stays on main (AppSettings is MainActor-isolated by
    /// default), but happens only once per ~150ms regardless of how many
    /// property mutations land in that window, and the write itself hops
    /// off-main. Trade-off: up to 150 ms of un-persisted state on a crash;
    /// acceptable since the values are user-toggleable and we'd re-derive
    /// them anyway. Matches the debounce shape used by
    /// `PiAgentSessionStore.scheduleSave`.
    private var pendingPersistTask: Task<Void, Never>?
    private static let persistDebounceNanoseconds: UInt64 = 150_000_000

    private func schedulePersist() {
        pendingPersistTask?.cancel()
        let key = defaultsKey
        pendingPersistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.persistDebounceNanoseconds)
            guard !Task.isCancelled, let self else { return }
            guard let data = try? JSONEncoder().encode(self.settings) else { return }
            // UserDefaults.set is itself thread-safe; hop off-main so the
            // disk I/O doesn't sit on the actor.
            Task.detached(priority: .utility) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    private init() {
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }
}
