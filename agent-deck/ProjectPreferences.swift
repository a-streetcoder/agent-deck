import AppKit
import Foundation

struct ProjectPreference: Codable, Hashable, Identifiable, Sendable {
    let path: String
    var isEnabled: Bool
    var isFavorite: Bool
    var isHidden: Bool
    var customIconPath: String?
    var assignedAgentNames: Set<String>
    var assignedSkillNames: Set<String>
    var assignedPromptTemplateNames: Set<String>

    var id: String { path }

    static func `default`(for path: String) -> ProjectPreference {
        ProjectPreference(path: path, isEnabled: false, isFavorite: false, isHidden: false, customIconPath: nil, assignedAgentNames: [], assignedSkillNames: [], assignedPromptTemplateNames: [])
    }

    enum CodingKeys: String, CodingKey {
        case path, isEnabled, isFavorite, isHidden, customIconPath, assignedAgentNames, assignedSkillNames, assignedPromptTemplateNames
    }

    init(path: String, isEnabled: Bool, isFavorite: Bool, isHidden: Bool, customIconPath: String?, assignedAgentNames: Set<String> = [], assignedSkillNames: Set<String> = [], assignedPromptTemplateNames: Set<String> = []) {
        self.path = path
        self.isEnabled = isEnabled
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.customIconPath = customIconPath
        self.assignedAgentNames = assignedAgentNames
        self.assignedSkillNames = assignedSkillNames
        self.assignedPromptTemplateNames = assignedPromptTemplateNames
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        customIconPath = try container.decodeIfPresent(String.self, forKey: .customIconPath)
        assignedAgentNames = try container.decodeIfPresent(Set<String>.self, forKey: .assignedAgentNames) ?? []
        assignedSkillNames = try container.decodeIfPresent(Set<String>.self, forKey: .assignedSkillNames) ?? []
        assignedPromptTemplateNames = try container.decodeIfPresent(Set<String>.self, forKey: .assignedPromptTemplateNames) ?? []
    }
}

@MainActor
final class ProjectPreferencesStore {
    static let shared = ProjectPreferencesStore()

    private let defaults = UserDefaults.standard
    private let storageKey = "projectPreferences.v1"
    private let fileManager = FileManager.default

    private(set) var preferencesByPath: [String: ProjectPreference]

    private init() {
        preferencesByPath = Self.loadPreferences(from: defaults, key: storageKey)
    }

    func addProjectPath(_ path: String) {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if preferencesByPath[standardizedPath] == nil {
            preferencesByPath[standardizedPath] = .default(for: standardizedPath)
            persist()
            return
        }

        if preferencesByPath[standardizedPath]?.isHidden == true {
            update(standardizedPath) { $0.isHidden = false }
        }
    }

    func setEnabled(_ isEnabled: Bool, for path: String) {
        update(path) { $0.isEnabled = isEnabled }
    }

    func toggleFavorite(for path: String) {
        update(path) { $0.isFavorite.toggle() }
    }

    func setFavorite(_ isFavorite: Bool, for path: String) {
        update(path) { $0.isFavorite = isFavorite }
    }

    func setHidden(_ isHidden: Bool, for path: String) {
        update(path) { $0.isHidden = isHidden }
    }

    func setAssignedAgent(_ agentName: String, assigned: Bool, for path: String) {
        update(path) { preference in
            if assigned {
                preference.assignedAgentNames.insert(agentName)
            } else {
                preference.assignedAgentNames.remove(agentName)
            }
        }
    }

    func setAssignedSkill(_ skillName: String, assigned: Bool, for path: String) {
        update(path) { preference in
            if assigned {
                preference.assignedSkillNames.insert(skillName)
            } else {
                preference.assignedSkillNames.remove(skillName)
            }
        }
    }

    func setAssignedPromptTemplate(_ promptName: String, assigned: Bool, for path: String) {
        update(path) { preference in
            if assigned {
                preference.assignedPromptTemplateNames.insert(promptName)
            } else {
                preference.assignedPromptTemplateNames.remove(promptName)
            }
        }
    }

    func renameAssignedAgent(from oldName: String, to newName: String) {
        guard oldName != newName else { return }
        var changed = false
        for path in preferencesByPath.keys {
            guard preferencesByPath[path]?.assignedAgentNames.contains(oldName) == true else { continue }
            preferencesByPath[path]?.assignedAgentNames.remove(oldName)
            preferencesByPath[path]?.assignedAgentNames.insert(newName)
            changed = true
        }
        if changed { persist() }
    }

    func renameAssignedSkill(from oldName: String, to newName: String) {
        guard oldName != newName else { return }
        var changed = false
        for path in preferencesByPath.keys {
            guard preferencesByPath[path]?.assignedSkillNames.contains(oldName) == true else { continue }
            preferencesByPath[path]?.assignedSkillNames.remove(oldName)
            preferencesByPath[path]?.assignedSkillNames.insert(newName)
            changed = true
        }
        if changed { persist() }
    }

    func renameAssignedPromptTemplate(from oldName: String, to newName: String) {
        guard oldName != newName else { return }
        var changed = false
        for path in preferencesByPath.keys {
            guard preferencesByPath[path]?.assignedPromptTemplateNames.contains(oldName) == true else { continue }
            preferencesByPath[path]?.assignedPromptTemplateNames.remove(oldName)
            preferencesByPath[path]?.assignedPromptTemplateNames.insert(newName)
            changed = true
        }
        if changed { persist() }
    }

    func setAllEnabled(_ isEnabled: Bool, for paths: [String]) {
        let normalizedPaths = paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        for path in normalizedPaths {
            var preference = preferencesByPath[path] ?? .default(for: path)
            preference.isEnabled = isEnabled
            preference.isHidden = false
            preferencesByPath[path] = preference
        }
        persist()
    }

    func setCustomIcon(from sourceURL: URL, for path: String) throws {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let iconsDirectoryURL = try ensureIconsDirectory()
        let fileExtension = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension.lowercased()
        let destinationURL = iconsDirectoryURL.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        let previousIconPath = preference(for: standardizedPath).customIconPath
        update(standardizedPath) { $0.customIconPath = destinationURL.path }
        removeIconIfNeeded(at: previousIconPath, excluding: destinationURL.path)
    }

    func clearCustomIcon(for path: String) {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let previousIconPath = preference(for: standardizedPath).customIconPath
        update(standardizedPath) { $0.customIconPath = nil }
        removeIconIfNeeded(at: previousIconPath, excluding: nil)
    }

    func preference(for path: String) -> ProjectPreference {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        return preferencesByPath[standardizedPath] ?? .default(for: standardizedPath)
    }

    private func update(_ path: String, mutate: (inout ProjectPreference) -> Void) {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        var preference = preferencesByPath[standardizedPath] ?? .default(for: standardizedPath)
        mutate(&preference)
        preferencesByPath[standardizedPath] = preference
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Array(preferencesByPath.values).sorted { $0.path < $1.path }) else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }

    private func ensureIconsDirectory() throws -> URL {
        let appSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = appSupportURL
            .appendingPathComponent("agent-deck", isDirectory: true)
            .appendingPathComponent("project-icons", isDirectory: true)

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func removeIconIfNeeded(at path: String?, excluding excludedPath: String?) {
        guard let path, path != excludedPath, fileManager.fileExists(atPath: path) else { return }
        try? fileManager.removeItem(atPath: path)
    }

    private static func loadPreferences(from defaults: UserDefaults, key: String) -> [String: ProjectPreference] {
        guard let data = defaults.data(forKey: key),
              let preferences = try? JSONDecoder().decode([ProjectPreference].self, from: data) else {
            return [:]
        }

        return Dictionary(uniqueKeysWithValues: preferences.map { preference in
            let standardizedPath = URL(fileURLWithPath: preference.path).standardizedFileURL.path
            return (standardizedPath, ProjectPreference(
                path: standardizedPath,
                isEnabled: preference.isEnabled,
                isFavorite: preference.isFavorite,
                isHidden: preference.isHidden,
                customIconPath: preference.customIconPath,
                assignedAgentNames: preference.assignedAgentNames,
                assignedSkillNames: preference.assignedSkillNames,
                assignedPromptTemplateNames: preference.assignedPromptTemplateNames
            ))
        })
    }
}
