import Foundation

nonisolated struct DiscoveredProject: Identifiable, Hashable, Sendable {
    let url: URL
    let gitHubRemote: GitHubRemote?
    let isGitRepository: Bool
    let iconFileURL: URL?
    let projectType: ProjectType
    let fallbackSymbolName: String
    let searchIndex: String

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var path: String { url.path }
    var repositoryName: String? { gitHubRemote?.nameWithOwner }
    var repositoryDisplayName: String { repositoryName ?? name }
    var isGitHubRepository: Bool { gitHubRemote?.isGitHubDotCom == true }
}

nonisolated struct ProjectDiscovery {
    private let fileManager = FileManager.default

    static func suggestedRootDirectoryURL(fileManager: FileManager = .default) -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Documents/GitHub", isDirectory: true),
            home.appendingPathComponent("GitHub", isDirectory: true),
            home.appendingPathComponent("Code", isDirectory: true),
            home.appendingPathComponent("Developer", isDirectory: true)
        ].map(\.standardizedFileURL)

        return candidates.first { directoryExists($0, fileManager: fileManager) }
    }

    static func defaultRootDirectoryURL(fileManager: FileManager = .default) -> URL {
        suggestedRootDirectoryURL(fileManager: fileManager)
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents/GitHub", isDirectory: true).standardizedFileURL
    }

    func discoverProjects(
        rootDirectoryURL: URL = ProjectDiscovery.defaultRootDirectoryURL(),
        additionalProjectPaths: [String] = [],
        preferencesByPath: [String: ProjectPreference] = [:]
    ) -> [DiscoveredProject] {
        discoverProjects(
            rootDirectoryURLs: [rootDirectoryURL],
            additionalProjectPaths: additionalProjectPaths,
            preferencesByPath: preferencesByPath
        )
    }

    /// Scans every supplied root in order, returning a single de-duplicated,
    /// alphabetically sorted list. Roots that resolve to the same canonical
    /// path (e.g. a symlinked alias) are only walked once.
    func discoverProjects(
        rootDirectoryURLs: [URL],
        additionalProjectPaths: [String] = [],
        preferencesByPath: [String: ProjectPreference] = [:]
    ) -> [DiscoveredProject] {
        var seenPaths = Set<String>()
        var projects: [DiscoveredProject] = []

        func appendProject(_ url: URL, allowManualDirectory: Bool) {
            let standardizedURL = url.standardizedFileURL

            // Memoize the recursive `.xcodeproj`/`.xcworkspace` descendant scan.
            // It is consulted by BOTH the project-ness test and the project-type
            // classifier and walks up to two directory levels, so without this it
            // ran twice per candidate (and eagerly, even for plain git repos that
            // never needed it). This dominated the discovery cost in scan
            // profiles.
            var cachedHasXcodeProject: Bool?
            func hasXcodeProject() -> Bool {
                if let cachedHasXcodeProject { return cachedHasXcodeProject }
                // Skip the recursive descendant walk when the candidate's own
                // contents are unchanged since a prior scan. The walk is the
                // single largest cost of discovery and otherwise re-runs every
                // refresh — sampling caught it starving the UI for ~270ms while
                // a session streamed. Keyed on the candidate directory's
                // content-modification date, which moves whenever a top-level
                // `.xcodeproj`/`.xcworkspace` is added or removed.
                let modified = (try? standardizedURL.resourceValues(
                    forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let result = XcodeDescendantWalkCache.shared.contains(
                    directory: standardizedURL.path, modified: modified
                ) {
                    containsDescendant(withExtensions: ["xcodeproj", "xcworkspace"], in: standardizedURL, maxDepth: 2)
                }
                cachedHasXcodeProject = result
                return result
            }

            guard allowManualDirectory ? isExistingDirectory(standardizedURL) : isProjectDirectory(standardizedURL, hasXcodeProject: hasXcodeProject) else { return }
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

            let projectType = ProjectType.detect(at: standardizedURL, fileManager: fileManager, hasXcodeProject: hasXcodeProject)
            projects.append(DiscoveredProject(
                url: standardizedURL,
                gitHubRemote: remote,
                isGitRepository: hasGitRepository(standardizedURL),
                iconFileURL: preference?.customIconPath.flatMap { URL(fileURLWithPath: $0) },
                projectType: projectType,
                fallbackSymbolName: projectType.sfSymbolFallback,
                searchIndex: searchIndex
            ))
        }

        var visitedRoots = Set<String>()
        for rootURL in rootDirectoryURLs {
            let root = rootURL.standardizedFileURL
            guard visitedRoots.insert(root.path).inserted else { continue }
            let children = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in children {
                // A dependency directory can itself sit directly under a configured
                // projects root. Treating it as a candidate makes the fallback Xcode
                // search walk thousands of packages before any real project is
                // published, leaving the library apparently empty during startup.
                guard url.lastPathComponent != "node_modules", url.lastPathComponent != "Pods" else { continue }
                appendProject(url, allowManualDirectory: false)
            }
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

    /// `hasXcodeProject` is the caller's memoized descendant scan — checked last
    /// so plain git repos and Node packages (the common case) never pay for the
    /// recursive `.xcodeproj` walk.
    private func isProjectDirectory(_ url: URL, hasXcodeProject: () -> Bool) -> Bool {
        guard isExistingDirectory(url) else {
            return false
        }

        let gitDirectory = url.appendingPathComponent(".git")
        if fileManager.fileExists(atPath: gitDirectory.path) { return true }
        let packageFile = url.appendingPathComponent("package.json")
        if fileManager.fileExists(atPath: packageFile.path) { return true }
        return hasXcodeProject()
    }

    private func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func containsDescendant(withExtensions pathExtensions: Set<String>, in url: URL, maxDepth: Int) -> Bool {
        guard maxDepth >= 0,
              let children = try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return false }

        for child in children {
            if pathExtensions.contains(child.pathExtension) {
                return true
            }

            guard maxDepth > 0,
                  let resourceValues = try? child.resourceValues(forKeys: [.isDirectoryKey]),
                  resourceValues.isDirectory == true else { continue }

            // Never descend into dependency trees: they can hold thousands of
            // entries, and an `.xcodeproj` found inside one is never the user's
            // own project.
            if child.lastPathComponent == "node_modules" || child.lastPathComponent == "Pods" { continue }

            if containsDescendant(withExtensions: pathExtensions, in: child, maxDepth: maxDepth - 1) {
                return true
            }
        }

        return false
    }

    private static func directoryExists(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// Process-wide memo for the depth-2 `.xcodeproj`/`.xcworkspace` descendant
/// walk in `ProjectDiscovery`, the dominant cost of a project scan. Scans
/// re-run often (file-watch events, project switches, every catalog edit), and
/// each previously re-walked every candidate's subtree from scratch. The result
/// only changes when the candidate directory's own contents change, so it is
/// cached against that directory's content-modification date and the walk is
/// skipped while the date is unchanged. Reached from background scan tasks that
/// can briefly overlap (a new refresh starts before the cancelled one unwinds),
/// so access is lock-guarded.
nonisolated private final class XcodeDescendantWalkCache: @unchecked Sendable {
    static let shared = XcodeDescendantWalkCache()
    private let lock = NSLock()
    private var entries: [String: (modified: Date, contains: Bool)] = [:]

    /// Returns the cached answer when `modified` matches the stored stamp;
    /// otherwise runs `walk`, stores its result, and returns it. A nil
    /// `modified` (e.g. the directory vanished mid-scan) always recomputes and
    /// is not cached.
    func contains(directory path: String, modified: Date?, walk: () -> Bool) -> Bool {
        if let modified {
            lock.lock()
            let hit = entries[path]
            lock.unlock()
            if let hit, hit.modified == modified { return hit.contains }
        }
        let result = walk()
        if let modified {
            lock.lock()
            entries[path] = (modified, result)
            lock.unlock()
        }
        return result
    }
}
