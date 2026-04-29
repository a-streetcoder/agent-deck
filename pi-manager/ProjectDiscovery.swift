import Foundation

struct DiscoveredProject: Identifiable, Hashable {
    let url: URL
    let repositoryName: String?

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var path: String { url.path }
    var repositoryDisplayName: String { repositoryName ?? name }
}

struct ProjectDiscovery {
    private let fileManager = FileManager.default

    func discoverProjects() -> [DiscoveredProject] {
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/GitHub", isDirectory: true)

        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return children.compactMap { url in
            guard isProjectDirectory(url) else { return nil }
            return DiscoveredProject(url: url, repositoryName: repositoryName(for: url))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func repositoryName(for url: URL) -> String? {
        let gitConfig = url.appendingPathComponent(".git/config")
        guard let text = try? String(contentsOf: gitConfig, encoding: .utf8) else {
            return nil
        }

        guard let remoteLine = text
            .split(whereSeparator: \.isNewline)
            .map({ String($0).trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.hasPrefix("url = ") }) else {
            return nil
        }

        let remoteURL = remoteLine.replacingOccurrences(of: "url = ", with: "")
        return normalizeRepositoryName(from: remoteURL)
    }

    private func normalizeRepositoryName(from remoteURL: String) -> String? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if let range = trimmed.range(of: "github.com:") {
            return String(trimmed[range.upperBound...]).replacingOccurrences(of: ".git", with: "")
        }

        if let range = trimmed.range(of: "github.com/") {
            return String(trimmed[range.upperBound...]).replacingOccurrences(of: ".git", with: "")
        }

        return nil
    }

    private func isProjectDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }

        let gitDirectory = url.appendingPathComponent(".git")
        let packageFile = url.appendingPathComponent("package.json")
        let xcodeProject = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?.contains {
            $0.pathExtension == "xcodeproj"
        } ?? false

        return fileManager.fileExists(atPath: gitDirectory.path) || fileManager.fileExists(atPath: packageFile.path) || xcodeProject
    }
}
