import Foundation

enum PiAgentThinkingDisplayMode: String, Codable, CaseIterable, Identifiable {
    case full = "Full"
    case compact = "Compact"
    case hidden = "Hidden"

    var id: String { rawValue }
}

struct PiAgentTranscriptVisibilitySettings: Codable, Hashable {
    var showThinking: Bool = true
    var showWebActivity: Bool = true
    var showToolCalls: Bool = true
    var showErrors: Bool = true
}

struct AppSettings: Codable, Hashable {
    var gitHubBoardCacheLifetimeMinutes: Int = 15
    var piAgentNotificationDelayMinutes: Int = 3
    var piAgentThinkingDisplayMode: PiAgentThinkingDisplayMode = .full
    var piAgentTranscriptVisibility: PiAgentTranscriptVisibilitySettings = .init()
    var piAgentTerminalApplicationPath: String?
    var projectsRootPath: String = ProjectDiscovery.defaultRootDirectoryURL().path
    var defaultSkillsImportRootPath: String?
    var nativeSubagentsEnabledForNewSessions: Bool = true
    var disabledModelIdentifiers: Set<String> = []

    enum CodingKeys: String, CodingKey {
        case gitHubBoardCacheLifetimeMinutes
        case piAgentNotificationDelayMinutes
        case piAgentThinkingDisplayMode
        case piAgentTranscriptVisibility
        case piAgentTerminalApplicationPath
        case projectsRootPath
        case defaultSkillsImportRootPath
        case nativeSubagentsEnabledForNewSessions
        case disabledModelIdentifiers
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gitHubBoardCacheLifetimeMinutes = try container.decodeIfPresent(Int.self, forKey: .gitHubBoardCacheLifetimeMinutes) ?? 15
        piAgentNotificationDelayMinutes = try container.decodeIfPresent(Int.self, forKey: .piAgentNotificationDelayMinutes) ?? 3
        piAgentThinkingDisplayMode = try container.decodeIfPresent(PiAgentThinkingDisplayMode.self, forKey: .piAgentThinkingDisplayMode) ?? .full
        piAgentTranscriptVisibility = try container.decodeIfPresent(PiAgentTranscriptVisibilitySettings.self, forKey: .piAgentTranscriptVisibility) ?? .init()
        piAgentTerminalApplicationPath = try container.decodeIfPresent(String.self, forKey: .piAgentTerminalApplicationPath)
        projectsRootPath = try container.decodeIfPresent(String.self, forKey: .projectsRootPath) ?? ProjectDiscovery.defaultRootDirectoryURL().path
        defaultSkillsImportRootPath = try container.decodeIfPresent(String.self, forKey: .defaultSkillsImportRootPath)
        nativeSubagentsEnabledForNewSessions = try container.decodeIfPresent(Bool.self, forKey: .nativeSubagentsEnabledForNewSessions) ?? true
        disabledModelIdentifiers = try container.decodeIfPresent(Set<String>.self, forKey: .disabledModelIdentifiers) ?? []
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
    private let defaultsKey = "piManagerAppSettings"

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

