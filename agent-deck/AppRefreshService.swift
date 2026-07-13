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
    /// Stable references resolved once for this refresh; consumers must not re-walk Codex cache.
    let resolvedCodexPluginSkillPaths: [CodexPluginSkillReference: String]
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
        codexPluginSkillReferences: Set<CodexPluginSkillReference> = [],
        /// Test seam; production resolves the currently active Codex packages.
        codexPluginPackages: [CodexPluginSkillDiscovery.Package]? = nil,
        skillCollectionNames: Set<String> = [],
        scanAllProjects: Bool = true,
        extraProjectPathsToScan: Set<String> = []
    ) -> AppRefreshSnapshot {
        let discovery = ProjectDiscovery()
        // Computer Use is an MCP-backed capability, not a Pi skill. Exclude only
        // its exact Codex plugin reference; other Codex plugin skills remain importable.
        let importablePluginReferences = codexPluginSkillReferences.filter { !ComputerUseCapability.isComputerUsePluginSkill($0) }
        let resolvedCodexPluginSkillPaths = CodexPluginSkillDiscovery.resolveAll(importablePluginReferences).mapValues(\.path)
        let installedCodexPackages = codexPluginPackages ?? CodexPluginSkillDiscovery.activePackages()
        // Legacy/local imports can point directly into the Codex cache. Exclude
        // only the verified installed Computer Use raw skill, not same-named
        // user-authored or copied folders.
        let importableExternalSkillPaths = externalSkillPaths.filter {
            !ComputerUseCapability.isInstalledRawSkill(at: URL(fileURLWithPath: $0), packages: installedCodexPackages)
        }
        let scanner = PiScanner(externalSkillPaths: importableExternalSkillPaths.union(Set(resolvedCodexPluginSkillPaths.values)), externalPromptPaths: externalPromptPaths, skillCollectionNames: skillCollectionNames)
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
        let watchedURLs = Self.watchedURLs(projects: projectsToWatch, snapshot: selectedProjectSnapshot ?? globalSnapshot, externalSkillPaths: importableExternalSkillPaths, externalPromptPaths: externalPromptPaths, codexPluginSkillReferences: importablePluginReferences, resolvedCodexPluginSkillPaths: resolvedCodexPluginSkillPaths)
        let pluginBaseURLs = Set(importablePluginReferences.compactMap { CodexPluginSkillDiscovery.pluginBaseDirectory(for: $0)?.standardizedFileURL.path })
        let watchFingerprint = FileWatchFingerprint.make(urls: watchedURLs, shallowDirectoryPaths: pluginBaseURLs)

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
            resolvedCodexPluginSkillPaths: resolvedCodexPluginSkillPaths,
            watchFingerprint: watchFingerprint,
            includesWatchFingerprint: scanAllProjects || selectedProject != nil
        )
    }

    static func watchedURLs(projects: [DiscoveredProject], snapshot: ScanSnapshot, externalSkillPaths: Set<String>, externalPromptPaths: Set<String>, codexPluginSkillReferences: Set<CodexPluginSkillReference> = [], resolvedCodexPluginSkillPaths: [CodexPluginSkillReference: String] = [:]) -> [URL] {
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

        // Watch the skill-repositories root as a single recursive watch. Every
        // cloned repo lives under it, so this one entry covers all their skills
        // once `watchPaths(for:)` prunes the now-redundant per-skill directories.
        // Without it, each imported skill becomes its own watch path and the
        // FSEventStream exhausts the process file-descriptor limit (EMFILE).
        let skillRepositoriesRoot = SkillRepositorySyncService.repositoriesDirectoryURL()
        if FileManager.default.fileExists(atPath: skillRepositoriesRoot.path) {
            urls.append(skillRepositoriesRoot)
        }

        for project in projects {
            let piRoot = project.url.appendingPathComponent(".pi", isDirectory: true)
            urls.append(piRoot.appendingPathComponent("settings.json"))
            urls.append(piRoot.appendingPathComponent(".env"))
        }

        urls += snapshot.effectiveAgents.compactMap(\.sourcePath).map { URL(fileURLWithPath: $0) }
        urls += snapshot.libraryAgents.map { URL(fileURLWithPath: $0.filePath) }
        urls += snapshot.skills.map { URL(fileURLWithPath: $0.filePath) }
        urls += snapshot.librarySkills.map { URL(fileURLWithPath: $0.filePath) }
        urls += externalSkillPaths.map { URL(fileURLWithPath: $0) }
        urls += externalPromptPaths.map { URL(fileURLWithPath: $0) }
        // Stable plugin references follow Codex's active package. Watch each
        // referenced plugin base (not every cache marketplace) and config so a
        // version replacement or install-state change schedules a rescan.
        if !codexPluginSkillReferences.isEmpty {
            let codexHome = CodexPluginSkillDiscovery.codexHome()
            urls.append(codexHome.appendingPathComponent("config.toml"))
            urls += codexPluginSkillReferences.compactMap { CodexPluginSkillDiscovery.pluginBaseDirectory(for: $0, codexHome: codexHome) }
            urls += resolvedCodexPluginSkillPaths.values.map { URL(fileURLWithPath: $0) }
        }
        urls += (snapshot.promptTemplates + snapshot.libraryPromptTemplates).map { URL(fileURLWithPath: $0.filePath) }
        let globalSettingsPath = globalAgentRoot.appendingPathComponent("settings.json").standardizedFileURL.path
        urls += snapshot.settings
            .filter { URL(fileURLWithPath: $0.path).standardizedFileURL.path == globalSettingsPath }
            .flatMap(\.prompts)
            .map { URL(fileURLWithPath: $0) }

        var seen: Set<String> = []
        return urls.filter { seen.insert($0.path).inserted }
    }
}

nonisolated struct FileWatchFingerprint: Sendable {
    static func make(urls: [URL], shallowDirectoryPaths: Set<String> = []) -> String {
        let fileManager = FileManager.default
        let entries: [String] = urls.flatMap { url in
            if shallowDirectoryPaths.contains(url.standardizedFileURL.path) {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
                return ["\(url.path)::\(date)"]
            }
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

nonisolated final class FileWatchEventMonitor: @unchecked Sendable {
    private static let stateQueueKey = DispatchSpecificKey<Bool>()

    private let queue = DispatchQueue(label: "app.agent-deck.file-watch-events", qos: .utility)
    private let pathQueue = DispatchQueue(label: "app.agent-deck.file-watch-paths", qos: .utility)
    private let stateQueue = DispatchQueue(label: "app.agent-deck.file-watch-state", qos: .utility)
    private let generationLock = NSLock()
    private let latency: CFTimeInterval
    private let onChange: () -> Void

    private var generation: UInt64 = 0
    private var isStopped = true
    private var stream: FSEventStreamRef?
    private var watchedPaths: [String] = []

    init(latency: CFTimeInterval = 0.75, onChange: @escaping () -> Void) {
        self.latency = latency
        self.onChange = onChange
        stateQueue.setSpecific(key: Self.stateQueueKey, value: true)
    }

    deinit {
        stopSynchronously()
    }

    func updateWatchedURLs(_ urls: [URL]) {
        // Resolving watch roots can touch a large imported skill tree. Keep it
        // off the main actor and off the stream-state queue, so lifecycle stops
        // do not wait behind a long path rebuild.
        let updateGeneration = nextGeneration(isStopped: false)
        pathQueue.async { [self, urls, updateGeneration] in
            let paths = Self.watchPaths(for: urls)
            stateQueue.async { [self, paths, updateGeneration] in
                guard isCurrentGeneration(updateGeneration), paths != watchedPaths else { return }
                stopOnStateQueue()
                watchedPaths = paths
                startOnStateQueue(paths: paths)
            }
        }
    }

    func stop() {
        let stopGeneration = nextGeneration(isStopped: true)
        let stopStreams: @Sendable () -> Void = {
            guard self.isCurrentGeneration(stopGeneration) else { return }
            self.stopOnStateQueue()
            self.watchedPaths = []
        }
        if DispatchQueue.getSpecific(key: Self.stateQueueKey) == true {
            stopStreams()
        } else {
            stateQueue.async { stopStreams() }
        }
    }

    private func stopSynchronously() {
        let stopGeneration = nextGeneration(isStopped: true)
        let stopStreams: @Sendable () -> Void = {
            guard self.isCurrentGeneration(stopGeneration) else { return }
            self.stopOnStateQueue()
            self.watchedPaths = []
        }
        if DispatchQueue.getSpecific(key: Self.stateQueueKey) == true {
            stopStreams()
        } else {
            stateQueue.sync(execute: stopStreams)
        }
    }

    private func nextGeneration(isStopped: Bool) -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        generation &+= 1
        self.isStopped = isStopped
        return generation
    }

    private func isCurrentGeneration(_ value: UInt64) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation == value
    }

    private func shouldDeliverEvents() -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return !isStopped
    }

    private func stopOnStateQueue() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func startOnStateQueue(paths: [String]) {
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
            guard monitor.shouldDeliverEvents() else { return }
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
