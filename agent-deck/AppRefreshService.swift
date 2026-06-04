import CoreServices
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

/// Sendable wrapper around an `UnsafeMutablePointer` so a `@Sendable` closure
/// (such as the one passed to `DispatchQueue.concurrentPerform`) can write to
/// disjoint indices of a buffer concurrently. Callers must ensure the
/// underlying memory outlives every worker and that no two workers touch the
/// same index.
private nonisolated struct SendableMutablePointer<Element>: @unchecked Sendable {
    let base: UnsafeMutablePointer<Element>
}

nonisolated struct AppRefreshService: Sendable {
    func loadSnapshot(
        rootURLs: [URL],
        selectedProjectPath: String?,
        preferencesByPath: [String: ProjectPreference],
        externalSkillPaths: Set<String>,
        externalPromptPaths: Set<String>,
        scanAllProjects: Bool = true,
        extraProjectPathsToScan: Set<String> = []
    ) -> AppRefreshSnapshot {
        let discovery = ProjectDiscovery()
        let scanner = PiScanner(externalSkillPaths: externalSkillPaths, externalPromptPaths: externalPromptPaths)
        let discoveredProjects = discovery.discoverProjects(
            rootDirectoryURLs: rootURLs,
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
        // Parallelize per-project scans. `PiScanner` is a value type with no
        // shared mutable state, so each iteration gets its own scan. We use
        // `concurrentPerform` (blocking) to keep `loadSnapshot` itself sync —
        // the override-edit caller (`refreshSynchronouslyBlocksMainUntilDone`)
        // depends on the synchronous shape, and the two detached callers don't
        // care which thread the work runs on.
        let projectSnapshots: [String: ScanSnapshot]
        if projectsToScan.count > 1 {
            var snapshots = [ScanSnapshot?](repeating: nil, count: projectsToScan.count)
            snapshots.withUnsafeMutableBufferPointer { buffer in
                // `concurrentPerform` is synchronous, so the buffer lifetime
                // outlives every worker. Wrap the base pointer in an
                // `@unchecked Sendable` ref so the `@Sendable` closure can
                // write disjoint indices in parallel without the closure
                // capturing the inout `buffer` itself.
                let ref = SendableMutablePointer(base: buffer.baseAddress!)
                DispatchQueue.concurrentPerform(iterations: projectsToScan.count) { index in
                    ref.base[index] = scanner.scan(projectRoot: projectsToScan[index].url)
                }
            }
            projectSnapshots = Dictionary(uniqueKeysWithValues: zip(projectsToScan, snapshots).compactMap { project, snap -> (String, ScanSnapshot)? in
                guard let snap else { return nil }
                return (project.path, snap)
            })
        } else {
            projectSnapshots = Dictionary(uniqueKeysWithValues: projectsToScan.map { project in
                (project.path, scanner.scan(projectRoot: project.url))
            })
        }
        let selectedProjectSnapshot = selectedProject.flatMap { projectSnapshots[$0.path] }
        let projectsToWatch: [DiscoveredProject]
        if let selectedProject {
            projectsToWatch = [selectedProject]
        } else {
            projectsToWatch = scanAllProjects ? enabledProjects : projectsToScan
        }
        let watchedURLs = Self.watchedURLs(projects: projectsToWatch, snapshot: selectedProjectSnapshot ?? globalSnapshot, externalSkillPaths: externalSkillPaths, externalPromptPaths: externalPromptPaths)
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

    static func watchedURLs(projects: [DiscoveredProject], snapshot: ScanSnapshot, externalSkillPaths: Set<String>, externalPromptPaths: Set<String>) -> [URL] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let globalAgentRoot = home.appendingPathComponent(".pi/agent", isDirectory: true)
        let legacyGlobalAgentRoot = home.appendingPathComponent(".agents", isDirectory: true)
        var urls: [URL] = [
            globalAgentRoot.appendingPathComponent("agents", isDirectory: true),
            globalAgentRoot.appendingPathComponent("agent-library/agents", isDirectory: true),
            globalAgentRoot.appendingPathComponent("settings.json"),
            globalAgentRoot.appendingPathComponent(".env"),
            globalAgentRoot.appendingPathComponent("extensions", isDirectory: true),
            globalAgentRoot.appendingPathComponent("skills", isDirectory: true),
            globalAgentRoot.appendingPathComponent("prompts", isDirectory: true),
            globalAgentRoot.appendingPathComponent("prompt-library", isDirectory: true),
            legacyGlobalAgentRoot,
            legacyGlobalAgentRoot.appendingPathComponent("skills", isDirectory: true)
        ]

        // Watch known skill-library roots as single recursive watches. Every
        // skill below these roots is already covered, so `watchPaths(for:)` can
        // prune the now-redundant per-skill directories. Without this, each
        // imported skill becomes its own FSEvents watch path and can exhaust the
        // process file-descriptor limit (EMFILE).
        let sharedSkillLibrariesRoot = home.appendingPathComponent(".agents-skill-libraries", isDirectory: true)
        let skillRepositoriesRoot = SkillRepositorySyncService.repositoriesDirectoryURL()
        for root in [sharedSkillLibrariesRoot, skillRepositoriesRoot] where fileManager.fileExists(atPath: root.path) {
            urls.append(root)
        }

        for project in projects {
            let piRoot = project.url.appendingPathComponent(".pi", isDirectory: true)
            urls.append(piRoot.appendingPathComponent("agents", isDirectory: true))
            urls.append(piRoot.appendingPathComponent("settings.json"))
            urls.append(piRoot.appendingPathComponent(".env"))
            urls.append(piRoot.appendingPathComponent("extensions", isDirectory: true))
            urls.append(piRoot.appendingPathComponent("skills", isDirectory: true))
            urls.append(piRoot.appendingPathComponent("prompts", isDirectory: true))
            urls.append(project.url.appendingPathComponent(".agents", isDirectory: true))
        }

        urls += snapshot.effectiveAgents.compactMap(\.sourcePath).map { URL(fileURLWithPath: $0) }
        urls += snapshot.libraryAgents.map { URL(fileURLWithPath: $0.filePath) }
        urls += snapshot.skills.map { URL(fileURLWithPath: $0.filePath) }
        urls += snapshot.librarySkills.map { URL(fileURLWithPath: $0.filePath) }
        urls += externalSkillPaths.map { URL(fileURLWithPath: $0) }
        urls += externalPromptPaths.map { URL(fileURLWithPath: $0) }
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

nonisolated final class FileWatchEventMonitor {
    private let queue = DispatchQueue(label: "app.agent-deck.file-watch-events", qos: .utility)
    private let latency: CFTimeInterval
    private let onChange: () -> Void

    private var stream: FSEventStreamRef?
    private var watchedPaths: [String] = []

    init(latency: CFTimeInterval = 0.75, onChange: @escaping () -> Void) {
        self.latency = latency
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func updateWatchedURLs(_ urls: [URL]) {
        let paths = Self.watchPaths(for: urls)
        guard paths != watchedPaths else { return }
        stop()
        watchedPaths = paths
        start(paths: paths)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func start(paths: [String]) {
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<FileWatchEventMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.onChange()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private static func watchPaths(for urls: [URL]) -> [String] {
        let fileManager = FileManager.default
        var seen: Set<String> = []
        let directories = urls.compactMap { url -> String? in
            let standardized = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return standardized.path
            }
            let parent = standardized.deletingLastPathComponent()
            if fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return parent.path
            }
            return nil
        }
        .filter { !$0.isEmpty && seen.insert($0).inserted }
        .sorted()

        // FSEvents notifications are recursive — watching a directory already
        // reports events for every descendant. Drop any path nested under
        // another watched path so a single stream doesn't hold a file
        // descriptor per skill subdirectory. Hundreds of imported-repo skills
        // would otherwise exhaust the process fd limit (EMFILE), which then
        // breaks font loading, asset catalogs, and dlopen across the whole app.
        // `directories` is sorted, so each path's ancestor — if watched — is
        // the most recently kept entry.
        var collapsed: [String] = []
        for path in directories {
            if let ancestor = collapsed.last,
               path == ancestor || path.hasPrefix(ancestor + "/") {
                continue
            }
            collapsed.append(path)
        }
        return collapsed
    }
}
