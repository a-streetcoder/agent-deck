import Foundation

struct DiscoveredProject: Identifiable, Hashable {
    let url: URL
    let gitHubRemote: GitHubRemote?
    let isGitRepository: Bool
    let iconFileURL: URL?
    let fallbackSymbolName: String
    let searchIndex: String

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var path: String { url.path }
    var repositoryName: String? { gitHubRemote?.nameWithOwner }
    var repositoryDisplayName: String { repositoryName ?? name }
    var isGitHubRepository: Bool { gitHubRemote?.isGitHubDotCom == true }
}

struct ProjectDiscovery {
    private let fileManager = FileManager.default

    static func defaultRootDirectoryURL(fileManager: FileManager = .default) -> URL {
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Documents/GitHub", isDirectory: true),
            home.appendingPathComponent("GitHub", isDirectory: true),
            home.appendingPathComponent("Code", isDirectory: true),
            home.appendingPathComponent("Developer", isDirectory: true)
        ].map(\.standardizedFileURL)

        for candidate in candidates where directoryExists(candidate, fileManager: fileManager) {
            return candidate
        }

        return candidates.first ?? home.standardizedFileURL
    }

    func discoverProjects(
        rootDirectoryURL: URL = ProjectDiscovery.defaultRootDirectoryURL(),
        additionalProjectPaths: [String] = [],
        preferencesByPath: [String: ProjectPreference] = [:]
    ) -> [DiscoveredProject] {
        let root = rootDirectoryURL.standardizedFileURL

        let discoveredRootChildren = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var seenPaths = Set<String>()
        var projects: [DiscoveredProject] = []

        func appendProject(_ url: URL, allowManualDirectory: Bool) {
            let standardizedURL = url.standardizedFileURL
            guard allowManualDirectory ? isExistingDirectory(standardizedURL) : isProjectDirectory(standardizedURL) else { return }
            guard seenPaths.insert(standardizedURL.path).inserted else { return }

            let remote = gitHubRemote(for: standardizedURL)
            let preference = preferencesByPath[standardizedURL.path]
            guard preference?.isHidden != true else { return }
            let repositoryName = remote?.nameWithOwner ?? standardizedURL.lastPathComponent
            let searchIndex = [
                repositoryName,
                standardizedURL.lastPathComponent,
                standardizedURL.path
            ]
            .joined(separator: "\n")
            .lowercased()

            projects.append(DiscoveredProject(
                url: standardizedURL,
                gitHubRemote: remote,
                isGitRepository: hasGitRepository(standardizedURL),
                iconFileURL: preference?.customIconPath.flatMap { URL(fileURLWithPath: $0) },
                fallbackSymbolName: fallbackSymbolName(for: standardizedURL),
                searchIndex: searchIndex
            ))
        }

        for url in discoveredRootChildren {
            appendProject(url, allowManualDirectory: false)
        }

        for path in additionalProjectPaths {
            appendProject(URL(fileURLWithPath: path), allowManualDirectory: true)
        }

        return projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func gitHubRemote(for url: URL) -> GitHubRemote? {
        guard let gitConfig = gitConfigURL(for: url),
              let text = try? String(contentsOf: gitConfig, encoding: .utf8),
              let remoteURL = preferredRemoteURL(from: text)
        else {
            return nil
        }

        return parseGitHubRemote(from: remoteURL)
    }

    private func hasGitRepository(_ url: URL) -> Bool {
        gitConfigURL(for: url) != nil
    }

    private func gitConfigURL(for repositoryURL: URL) -> URL? {
        let dotGitURL = repositoryURL.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: dotGitURL.path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue {
            return dotGitURL.appendingPathComponent("config")
        }

        guard let gitdirLine = (try? String(contentsOf: dotGitURL, encoding: .utf8))?
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("gitdir:") })
        else {
            return nil
        }

        let gitdirPath = gitdirLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "gitdir:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let gitDirectoryURL = URL(fileURLWithPath: gitdirPath, relativeTo: repositoryURL).standardizedFileURL

        let commonDirURL: URL?
        if let commonDirPath = try? String(contentsOf: gitDirectoryURL.appendingPathComponent("commondir"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !commonDirPath.isEmpty {
            commonDirURL = URL(fileURLWithPath: commonDirPath, relativeTo: gitDirectoryURL).standardizedFileURL
        } else {
            commonDirURL = nil
        }

        let candidateURLs = [
            commonDirURL?.appendingPathComponent("config"),
            gitDirectoryURL.appendingPathComponent("config")
        ]

        return candidateURLs.compactMap { $0 }.first(where: { fileManager.fileExists(atPath: $0.path) })
    }

    private func preferredRemoteURL(from gitConfig: String) -> String? {
        var currentRemoteName: String?
        var firstRemoteURL: String?
        var originRemoteURL: String?

        for rawLine in gitConfig.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentRemoteName = remoteSectionName(from: line)
                continue
            }

            guard let currentRemoteName,
                  line.hasPrefix("url") else {
                continue
            }

            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }

            let remoteURL = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remoteURL.isEmpty else { continue }

            if firstRemoteURL == nil {
                firstRemoteURL = remoteURL
            }
            if currentRemoteName == "origin" {
                originRemoteURL = remoteURL
            }
        }

        return originRemoteURL ?? firstRemoteURL
    }

    private func remoteSectionName(from line: String) -> String? {
        guard line.hasPrefix("[remote \"") && line.hasSuffix("\"]") else {
            return nil
        }

        let start = line.index(line.startIndex, offsetBy: 9)
        let end = line.index(line.endIndex, offsetBy: -2)
        guard start <= end else { return nil }
        return String(line[start..<end])
    }

    private func parseGitHubRemote(from remoteURL: String) -> GitHubRemote? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if let remote = parseSSHGitHubRemote(from: trimmed) {
            return remote
        }

        if let remote = parseHTTPSGitHubRemote(from: trimmed) {
            return remote
        }

        return nil
    }

    private func parseSSHGitHubRemote(from remoteURL: String) -> GitHubRemote? {
        guard let range = remoteURL.range(of: "@") else { return nil }
        let remainder = remoteURL[range.upperBound...]
        guard let separator = remainder.firstIndex(of: ":") else { return nil }

        let host = String(remainder[..<separator])
        let path = String(remainder[remainder.index(after: separator)...])
        return buildRemote(host: host, path: path, remoteURL: remoteURL)
    }

    private func parseHTTPSGitHubRemote(from remoteURL: String) -> GitHubRemote? {
        guard let components = URLComponents(string: remoteURL), let host = components.host else {
            return nil
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return buildRemote(host: host, path: path, remoteURL: remoteURL)
    }

    private func buildRemote(host: String, path: String, remoteURL: String) -> GitHubRemote? {
        guard host.caseInsensitiveCompare("github.com") == .orderedSame else {
            return nil
        }

        let normalizedPath: String
        if path.hasSuffix(".git") {
            normalizedPath = String(path.dropLast(4))
        } else {
            normalizedPath = path
        }

        let components = normalizedPath.split(separator: "/")
        guard components.count >= 2 else { return nil }

        return GitHubRemote(
            host: host,
            owner: String(components[0]),
            repo: String(components[1]),
            remoteURL: remoteURL
        )
    }

    private func isProjectDirectory(_ url: URL) -> Bool {
        guard isExistingDirectory(url) else {
            return false
        }

        let gitDirectory = url.appendingPathComponent(".git")
        let packageFile = url.appendingPathComponent("package.json")
        let xcodeProject = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?.contains {
            $0.pathExtension == "xcodeproj"
        } ?? false

        return fileManager.fileExists(atPath: gitDirectory.path) || fileManager.fileExists(atPath: packageFile.path) || xcodeProject
    }

    private func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func fallbackSymbolName(for url: URL) -> String {
        if containsChild(withExtension: "xcodeproj", in: url) {
            return "apple.logo"
        }

        if fileManager.fileExists(atPath: url.appendingPathComponent("next.config.js").path) ||
            fileManager.fileExists(atPath: url.appendingPathComponent("next.config.mjs").path) ||
            fileManager.fileExists(atPath: url.appendingPathComponent("next.config.ts").path) {
            return "globe"
        }

        if fileManager.fileExists(atPath: url.appendingPathComponent("tauri.conf.json").path) ||
            fileManager.fileExists(atPath: url.appendingPathComponent("electron-builder.json").path) ||
            fileManager.fileExists(atPath: url.appendingPathComponent("electron.vite.config.ts").path) {
            return "macwindow"
        }

        if fileManager.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            return "shippingbox"
        }

        if fileManager.fileExists(atPath: url.appendingPathComponent("package.json").path) {
            return "curlybraces"
        }

        if fileManager.fileExists(atPath: url.appendingPathComponent("Cargo.toml").path) {
            return "gearshape.2"
        }

        return "folder"
    }

    private func containsChild(withExtension pathExtension: String, in url: URL) -> Bool {
        (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?.contains {
            $0.pathExtension == pathExtension
        } ?? false
    }

    private static func directoryExists(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
