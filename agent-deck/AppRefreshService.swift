import Foundation

struct AppRefreshSnapshot: Sendable {
    let projectPreferencesByPath: [String: ProjectPreference]
    let discoveredProjects: [DiscoveredProject]
    let enabledProjects: [DiscoveredProject]
    let globalSnapshot: ScanSnapshot
    let projectSnapshots: [String: ScanSnapshot]
    let includesAllProjectSnapshots: Bool
    let selectedProject: DiscoveredProject?
    let selectedProjectSnapshot: ScanSnapshot?
    let watchFingerprint: String
}

nonisolated struct AppRefreshService: Sendable {
    func loadSnapshot(
        rootURL: URL,
        selectedProjectPath: String?,
        preferencesByPath: [String: ProjectPreference],
        scanAllProjects: Bool = true
    ) -> AppRefreshSnapshot {
        let discovery = ProjectDiscovery()
        let scanner = PiScanner()
        let discoveredProjects = discovery.discoverProjects(
            rootDirectoryURL: rootURL,
            additionalProjectPaths: Array(preferencesByPath.keys),
            preferencesByPath: preferencesByPath
        )
        let enabledProjects = discoveredProjects.filter { project in
            preferencesByPath[project.path]?.isEnabled ?? true
        }
        let globalSnapshot = scanner.scan(projectRoot: nil)
        let selectedProject = selectedProjectPath.flatMap { path in
            discoveredProjects.first { project in
                project.path == path && (preferencesByPath[project.path]?.isEnabled ?? true)
            }
        }
        let projectsToScan = scanAllProjects ? enabledProjects : selectedProject.map { [$0] } ?? []
        let projectSnapshots = Dictionary(uniqueKeysWithValues: projectsToScan.map { project in
            (project.path, scanner.scan(projectRoot: project.url))
        })
        let selectedProjectSnapshot = selectedProject.flatMap { projectSnapshots[$0.path] }
        let watchFingerprint = FileWatchFingerprint.make(
            urls: Self.watchedURLs(enabledProjects: enabledProjects, snapshot: selectedProjectSnapshot ?? globalSnapshot)
        )

        return AppRefreshSnapshot(
            projectPreferencesByPath: preferencesByPath,
            discoveredProjects: discoveredProjects,
            enabledProjects: enabledProjects,
            globalSnapshot: globalSnapshot,
            projectSnapshots: projectSnapshots,
            includesAllProjectSnapshots: scanAllProjects,
            selectedProject: selectedProject,
            selectedProjectSnapshot: selectedProjectSnapshot,
            watchFingerprint: watchFingerprint
        )
    }

    static func watchedURLs(enabledProjects: [DiscoveredProject], snapshot: ScanSnapshot) -> [URL] {
        var urls: [URL] = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agents", isDirectory: true)
        ]

        for project in enabledProjects {
            urls.append(project.url.appendingPathComponent(".pi", isDirectory: true))
            urls.append(project.url.appendingPathComponent(".agents", isDirectory: true))
        }

        urls += snapshot.promptTemplates.map { URL(fileURLWithPath: $0.filePath) }
        urls += snapshot.settings.flatMap(\.prompts).map { URL(fileURLWithPath: $0) }

        var seen: Set<String> = []
        return urls.filter { seen.insert($0.path).inserted }
    }
}

nonisolated struct FileWatchFingerprint: Sendable {
    static func make(urls: [URL]) -> String {
        let fileManager = FileManager.default
        let entries: [String] = urls.flatMap { url in
            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
               values.isDirectory == true {
                let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
                var children: [String] = []
                while let child = enumerator?.nextObject() as? URL {
                    guard watchedFileName(child.lastPathComponent) else { continue }
                    let date = (try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
                    children.append("\(child.path)::\(date)")
                }
                return children
            }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
            return ["\(url.path)::\(date)"]
        }
        return entries.sorted().joined(separator: "|")
    }

    private static func watchedFileName(_ name: String) -> Bool {
        name.hasSuffix(".md") || name.hasSuffix(".json") || name == ".env" || name == "SKILL.md"
    }
}
