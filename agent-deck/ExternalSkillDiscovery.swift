import Foundation

/// Filesystem discovery of importable Agent Deck skills.
///
/// Every operation here is pure file I/O and is deliberately `nonisolated` so
/// it runs *off* the main actor. The recursive walk used to live on
/// `AppViewModel` (`@MainActor`) and was invoked synchronously, which froze the
/// whole UI while a large skills folder was scanned.
nonisolated enum ExternalSkillDiscovery {

    /// Live counters surfaced to the import sheet while a scan is running.
    nonisolated struct Progress: Sendable, Equatable {
        var directoriesScanned = 0
        var skillsFound = 0
    }

    /// Streamed scan output: zero or more `.progress` updates followed by
    /// exactly one terminal `.finished` (unless the scan is cancelled, in
    /// which case the stream simply finishes with no `.finished`).
    nonisolated enum Event: Sendable {
        case progress(Progress)
        case finished([ExternalSkillCandidate])
    }

    /// Directory names skipped wholesale during the walk. These never hold
    /// skill roots yet can contain tens of thousands of files. Dotfile
    /// directories (`.git`, `.venv`, …) are already skipped by
    /// `.skipsHiddenFiles`; they are listed anyway so the intent is explicit.
    static let defaultExcludedDirectoryNames: Set<String> = [
        "node_modules", ".git", ".svn", ".hg",
        ".build", "build", "DerivedData", "dist", "out", "target",
        ".venv", "venv", "env", "__pycache__", ".tox",
        ".next", ".nuxt", ".cache", ".gradle", ".idea", "Pods",
    ]

    /// Maximum directory depth descended from the chosen root. Guards against
    /// pathological trees and symlink-induced cycles.
    static let defaultMaxDepth = 16

    /// Number of directories scanned between progress reports.
    private static let progressReportInterval = 25

    /// Scan `root`, streaming progress updates and a final candidate list.
    ///
    /// The walk runs on a detached background task. Cancelling the task that
    /// consumes the returned stream (or simply dropping the stream) cancels the
    /// walk via the stream's `onTermination` handler.
    static func scan(
        root: URL,
        excludedDirectoryNames: Set<String> = defaultExcludedDirectoryNames,
        maxDepth: Int = defaultMaxDepth
    ) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let work = Task.detached(priority: .userInitiated) {
                let candidates = await discover(
                    root: root,
                    excludedDirectoryNames: excludedDirectoryNames,
                    maxDepth: maxDepth
                ) { progress in
                    continuation.yield(.progress(progress))
                }
                if !Task.isCancelled {
                    continuation.yield(.finished(candidates))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Walk `root` and return the sorted candidate list. Honours task
    /// cancellation and reports throttled progress through `onProgress`.
    ///
    /// Exposed directly (separately from `scan`) so it can be unit tested
    /// without wiring up an `AsyncStream`.
    static func discover(
        root: URL,
        excludedDirectoryNames: Set<String> = defaultExcludedDirectoryNames,
        maxDepth: Int = defaultMaxDepth,
        onProgress: (Progress) -> Void = { _ in }
    ) async -> [ExternalSkillCandidate] {
        let fileManager = FileManager.default
        var results: [ExternalSkillCandidate] = []
        var seenRootPaths = Set<String>()
        var stack: [(url: URL, depth: Int)] = [(root.standardizedFileURL, 0)]
        var directoriesScanned = 0
        var lastReportedCount = 0

        while let (directory, depth) = stack.popLast() {
            if Task.isCancelled { return [] }
            directoriesScanned += 1

            if let candidate = candidate(at: directory) {
                if seenRootPaths.insert(candidate.sourceRootPath).inserted {
                    results.append(candidate)
                }
                // A folder containing SKILL.md is a skill root; never descend
                // into its examples or nested reference skills.
            } else if depth < maxDepth,
                      let entries = try? fileManager.contentsOfDirectory(
                          at: directory,
                          includingPropertiesForKeys: [.isDirectoryKey],
                          options: [.skipsHiddenFiles]
                      ) {
                for entry in entries {
                    guard !excludedDirectoryNames.contains(entry.lastPathComponent) else { continue }
                    let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
                    guard isDirectory == true else { continue }
                    stack.append((entry.standardizedFileURL, depth + 1))
                }
            }

            if directoriesScanned - lastReportedCount >= progressReportInterval {
                lastReportedCount = directoriesScanned
                onProgress(Progress(directoriesScanned: directoriesScanned, skillsFound: results.count))
                await Task.yield()
            }
        }

        onProgress(Progress(directoriesScanned: directoriesScanned, skillsFound: results.count))

        return results.sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.sourceRootPath < rhs.sourceRootPath
        }
    }

    /// Build a candidate for a folder if it is a skill root (contains a
    /// readable `SKILL.md`). Returns `nil` otherwise.
    static func candidate(at skillRoot: URL) -> ExternalSkillCandidate? {
        let standardizedRoot = skillRoot.standardizedFileURL
        let skillFile = standardizedRoot.appendingPathComponent("SKILL.md")
        guard let frontmatter = SkillFrontmatter.fields(atTopOf: skillFile) else { return nil }

        let resolved = SkillFrontmatter.nameAndDescription(
            fromFrontmatter: frontmatter,
            fallbackName: standardizedRoot.lastPathComponent
        )

        return ExternalSkillCandidate(
            name: resolved.name,
            description: resolved.description,
            sourceRootPath: standardizedRoot.path,
            skillFilePath: skillFile.path
        )
    }
}
