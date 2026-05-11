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
    let watchedURLs: [URL]
    let watchFingerprint: String
    let includesWatchFingerprint: Bool
}

nonisolated struct AppRefreshService: Sendable {
    func loadSnapshot(
        rootURL: URL,
        selectedProjectPath: String?,
        preferencesByPath: [String: ProjectPreference],
        externalSkillPaths: Set<String>,
        scanAllProjects: Bool = true,
        extraProjectPathsToScan: Set<String> = []
    ) -> AppRefreshSnapshot {
        let discovery = ProjectDiscovery()
        let scanner = PiScanner(externalSkillPaths: externalSkillPaths)
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
        let projectsToScan: [DiscoveredProject]
        if scanAllProjects {
            projectsToScan = enabledProjects
        } else {
            var seen: Set<String> = []
            projectsToScan = ([selectedProject].compactMap { $0 } + enabledProjects.filter { extraProjectPathsToScan.contains($0.path) })
                .filter { seen.insert($0.path).inserted }
        }
        let projectSnapshots = Dictionary(uniqueKeysWithValues: projectsToScan.map { project in
            (project.path, scanner.scan(projectRoot: project.url))
        })
        let selectedProjectSnapshot = selectedProject.flatMap { projectSnapshots[$0.path] }
        let projectsToWatch: [DiscoveredProject]
        if let selectedProject {
            projectsToWatch = [selectedProject]
        } else {
            projectsToWatch = scanAllProjects ? enabledProjects : projectsToScan
        }
        let watchedURLs = Self.watchedURLs(projects: projectsToWatch, snapshot: selectedProjectSnapshot ?? globalSnapshot, externalSkillPaths: externalSkillPaths)
        let watchFingerprint = FileWatchFingerprint.make(urls: watchedURLs)

        return AppRefreshSnapshot(
            projectPreferencesByPath: preferencesByPath,
            discoveredProjects: discoveredProjects,
            enabledProjects: enabledProjects,
            globalSnapshot: globalSnapshot,
            projectSnapshots: projectSnapshots,
            includesAllProjectSnapshots: scanAllProjects,
            selectedProject: selectedProject,
            selectedProjectSnapshot: selectedProjectSnapshot,
            watchedURLs: watchedURLs,
            watchFingerprint: watchFingerprint,
            includesWatchFingerprint: scanAllProjects || selectedProject != nil
        )
    }

    static func watchedURLs(projects: [DiscoveredProject], snapshot: ScanSnapshot, externalSkillPaths: Set<String>) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let globalAgentRoot = home.appendingPathComponent(".pi/agent", isDirectory: true)
        let legacyGlobalAgentRoot = home.appendingPathComponent(".agents", isDirectory: true)
        var urls: [URL] = [
            globalAgentRoot.appendingPathComponent("agents", isDirectory: true),
            globalAgentRoot.appendingPathComponent("agent-library/agents", isDirectory: true),
            globalAgentRoot.appendingPathComponent("settings.json"),
            globalAgentRoot.appendingPathComponent(".env"),
            globalAgentRoot.appendingPathComponent("skills", isDirectory: true),
            globalAgentRoot.appendingPathComponent("prompts", isDirectory: true),
            globalAgentRoot.appendingPathComponent("prompt-library", isDirectory: true),
            legacyGlobalAgentRoot,
            legacyGlobalAgentRoot.appendingPathComponent("skills", isDirectory: true)
        ]

        for project in projects {
            let piRoot = project.url.appendingPathComponent(".pi", isDirectory: true)
            urls.append(piRoot.appendingPathComponent("agents", isDirectory: true))
            urls.append(piRoot.appendingPathComponent("settings.json"))
            urls.append(piRoot.appendingPathComponent(".env"))
            urls.append(piRoot.appendingPathComponent("skills", isDirectory: true))
            urls.append(piRoot.appendingPathComponent("prompts", isDirectory: true))
            urls.append(project.url.appendingPathComponent(".agents", isDirectory: true))
        }

        urls += snapshot.effectiveAgents.compactMap(\.sourcePath).map { URL(fileURLWithPath: $0) }
        urls += snapshot.libraryAgents.map { URL(fileURLWithPath: $0.filePath) }
        urls += snapshot.skills.map { URL(fileURLWithPath: $0.filePath) }
        urls += snapshot.librarySkills.map { URL(fileURLWithPath: $0.filePath) }
        urls += externalSkillPaths.map { URL(fileURLWithPath: $0) }
        urls += (snapshot.promptTemplates + snapshot.libraryPromptTemplates).map { URL(fileURLWithPath: $0.filePath) }
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
                let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey],
                    options: [.skipsPackageDescendants]
                )
                var children: [String] = []
                while let child = enumerator?.nextObject() as? URL {
                    let childValues = try? child.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey])
                    if childValues?.isDirectory == true {
                        if shouldSkipDirectory(child.lastPathComponent) {
                            enumerator?.skipDescendants()
                        }
                        continue
                    }
                    guard childValues?.isRegularFile == true, watchedFile(child) else { continue }
                    let date = childValues?.contentModificationDate?.timeIntervalSince1970 ?? 0
                    children.append("\(child.path)::\(date)")
                }
                return children
            }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
            return ["\(url.path)::\(date)"]
        }
        return entries.sorted().joined(separator: "|")
    }

    private static func watchedFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name == ".env" || name == "SKILL.md" { return true }
        switch url.pathExtension.lowercased() {
        case "md", "json":
            return true
        default:
            return false
        }
    }

    private static func shouldSkipDirectory(_ name: String) -> Bool {
        let skipped: Set<String> = [
            ".git",
            ".hg",
            ".svn",
            ".build",
            "node_modules",
            "DerivedData",
            "Subagent Runs",
            "sessions",
            "logs"
        ]
        return skipped.contains(name)
    }
}
