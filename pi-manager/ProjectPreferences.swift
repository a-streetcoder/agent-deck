import AppKit
import Foundation

struct ProjectPreference: Codable, Hashable, Identifiable {
    let path: String
    var isEnabled: Bool
    var isFavorite: Bool
    var customIconPath: String?

    var id: String { path }

    static func `default`(for path: String) -> ProjectPreference {
        ProjectPreference(path: path, isEnabled: false, isFavorite: false, customIconPath: nil)
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
            .appendingPathComponent("pi-manager", isDirectory: true)
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
                customIconPath: preference.customIconPath
            ))
        })
    }
}
