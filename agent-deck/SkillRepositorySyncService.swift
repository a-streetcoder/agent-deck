import Foundation

/// Git-backed sync for skill repositories imported from GitHub / skills.sh.
///
/// Every method is pure shell I/O over `git` and `async`, so it runs off the
/// main actor — mirroring `ExternalSkillDiscovery` and `GitRepositoryService`.
///
/// Discovery uses a blobless, sparse clone (`--filter=blob:none --sparse`):
/// commit and tree metadata download immediately, file contents are fetched
/// lazily. Importing selected skills runs `git sparse-checkout set` so only the
/// chosen skill directories — and the reference files nested inside them — are
/// materialised on disk.
nonisolated struct SkillRepositorySyncService {
    enum SyncError: LocalizedError {
        case invalidSource(String)
        case cloneFailed(String)
        case gitCommandFailed(command: String, message: String)
        case updateCheckFailed(String)
        case updateFailed(String)

        var errorDescription: String? {
            switch self {
            case let .invalidSource(message): return message
            case let .cloneFailed(message): return "Could not clone the repository. \(message)"
            case let .gitCommandFailed(command, message):
                return message.isEmpty ? "`\(command)` failed." : "`\(command)` failed: \(message)"
            case let .updateCheckFailed(message): return "Could not check for updates. \(message)"
            case let .updateFailed(message): return "Could not apply the update. \(message)"
            }
        }
    }

    private let commandRunner: CommandRunning

    /// Prevents git from blocking on an interactive credential prompt — a
    /// private repo without configured credentials fails fast instead.
    private let gitEnvironment = ["GIT_TERMINAL_PROMPT": "0"]

    init(commandRunner: CommandRunning = CommandRunner()) {
        self.commandRunner = commandRunner
    }

    // MARK: - Storage locations

    /// App-managed root that holds every cloned skill repository.
    static func repositoriesDirectoryURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent(AppBrand.displayName, isDirectory: true)
            .appendingPathComponent("SkillRepositories", isDirectory: true)
    }

    /// Per-repository clone directory, e.g. `…/SkillRepositories/dimillian-skills`.
    static func cloneDirectoryURL(owner: String, repo: String) -> URL {
        repositoriesDirectoryURL()
            .appendingPathComponent(sanitizedPathComponent("\(owner)-\(repo)"), isDirectory: true)
    }

    private static func sanitizedPathComponent(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        let mapped = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(mapped).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "repository" : trimmed
    }

    // MARK: - Source parsing

    /// Parse user input into a `RemoteSkillSource`. Accepts GitHub URLs,
    /// `owner/repo` shorthand, skills.sh URLs, SSH remotes, and generic git
    /// URLs. Pure — no network or disk access.
    static func resolveSource(from rawInput: String) throws -> RemoteSkillSource {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            throw SyncError.invalidSource("Enter a GitHub or skills.sh URL.")
        }

        // A host-prefixed input without a scheme (`github.com/owner/repo`) is
        // treated as an https URL so the URL parsers can handle it. A bare
        // `owner/repo` shorthand has no dotted first segment and is left as-is.
        let normalized: String
        if !input.contains("://"),
           !input.hasPrefix("git@"),
           let firstSegment = input.split(separator: "/").first,
           firstSegment.contains(".") {
            normalized = "https://" + input
        } else {
            normalized = input
        }

        if let source = parseSkillsShURL(normalized) { return source }
        if normalized.hasPrefix("git@"), let source = parseSSHRemote(normalized) { return source }
        if normalized.contains("://"), let source = parseWebURL(normalized) { return source }
        if let source = parseShorthand(normalized) { return source }

        throw SyncError.invalidSource(
            "Could not read a repository from “\(input)”. Use a GitHub URL, owner/repo, or a skills.sh link."
        )
    }

    /// skills.sh is a directory site over GitHub repos:
    /// `skills.sh/<owner>/<repo>[/<skill-slug>]` → `github.com/<owner>/<repo>`.
    private static func parseSkillsShURL(_ input: String) -> RemoteSkillSource? {
        let lowered = input.lowercased()
        guard lowered.contains("skills.sh/") else { return nil }
        guard let host = input.range(of: "skills.sh/", options: .caseInsensitive) else { return nil }
        let pathPart = String(input[host.upperBound...])
        let pathWithoutQuery = pathPart.split(separator: "?", maxSplits: 1).first.map(String.init) ?? pathPart
        let components = pathWithoutQuery
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        let reserved: Set<String> = ["docs", "topics", "agents", "leaderboard", "trending", "hot", "official", "new", "search"]
        guard components.count >= 2, !reserved.contains(components[0].lowercased()) else { return nil }
        let owner = components[0]
        let repo = stripGitSuffix(components[1])
        let slug = components.count >= 3 ? components[2] : nil
        return RemoteSkillSource(
            remoteURL: "https://github.com/\(owner)/\(repo).git",
            owner: owner,
            repo: repo,
            ref: nil,
            preselectedSkillSlug: slug
        )
    }

    /// `git@host:owner/repo(.git)` → normalized https remote.
    private static func parseSSHRemote(_ input: String) -> RemoteSkillSource? {
        let body = String(input.dropFirst("git@".count))
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let host = String(body[..<colon])
        let path = String(body[body.index(after: colon)...])
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 2 else { return nil }
        let owner = components[0]
        let repo = stripGitSuffix(components[1])
        return RemoteSkillSource(
            remoteURL: "https://\(host)/\(owner)/\(repo).git",
            owner: owner,
            repo: repo,
            ref: nil,
            preselectedSkillSlug: nil
        )
    }

    /// A `https://host/owner/repo[/tree/<branch>[/<path>]]` URL.
    private static func parseWebURL(_ input: String) -> RemoteSkillSource? {
        guard let components = URLComponents(string: input),
              let host = components.host else { return nil }
        // skills.sh links are handled by `parseSkillsShURL`; anything left here
        // (a docs/topics page) is not a cloneable repository.
        guard !host.lowercased().contains("skills.sh") else { return nil }
        let path = components.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard path.count >= 2 else { return nil }
        let owner = path[0]
        let repo = stripGitSuffix(path[1])

        var ref: String?
        var slug: String?
        // GitHub: /owner/repo/tree/<branch>/<path…>   GitLab: /owner/repo/-/tree/<branch>/<path…>
        if let treeIndex = path.firstIndex(of: "tree"), treeIndex >= 2, treeIndex + 1 < path.count {
            ref = path[treeIndex + 1]
            let remainder = path[(treeIndex + 2)...]
            if !remainder.isEmpty { slug = remainder.joined(separator: "/") }
        }

        return RemoteSkillSource(
            remoteURL: "https://\(host)/\(owner)/\(repo).git",
            owner: owner,
            repo: repo,
            ref: ref,
            preselectedSkillSlug: slug
        )
    }

    /// `owner/repo` shorthand, assumed to be a GitHub repository.
    private static func parseShorthand(_ input: String) -> RemoteSkillSource? {
        let components = input.split(separator: "/").map(String.init)
        guard components.count == 2 else { return nil }
        let pattern = /^[A-Za-z0-9._-]+$/
        guard components.allSatisfy({ $0.wholeMatch(of: pattern) != nil }) else { return nil }
        let owner = components[0]
        let repo = stripGitSuffix(components[1])
        return RemoteSkillSource(
            remoteURL: "https://github.com/\(owner)/\(repo).git",
            owner: owner,
            repo: repo,
            ref: nil,
            preselectedSkillSlug: nil
        )
    }

    private static func stripGitSuffix(_ name: String) -> String {
        name.hasSuffix(".git") ? String(name.dropLast(4)) : name
    }

    // MARK: - Discovery

    /// Clone `source` blobless + sparse into `clonePath` so its skills can be
    /// listed. No skill content is materialised yet. Any existing directory at
    /// `clonePath` is removed first.
    func cloneForDiscovery(_ source: RemoteSkillSource, into clonePath: URL) async throws -> ClonedRepositoryInfo {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: clonePath.path) {
            try fileManager.removeItem(at: clonePath)
        }
        try fileManager.createDirectory(at: clonePath.deletingLastPathComponent(), withIntermediateDirectories: true)

        func cloneArguments(includeFilter: Bool) -> [String] {
            var arguments = ["clone"]
            if includeFilter { arguments.append("--filter=blob:none") }
            arguments.append("--sparse")
            if let ref = source.ref, !ref.isEmpty {
                arguments += ["--branch", ref, "--single-branch"]
            }
            arguments += [source.remoteURL, clonePath.path]
            return arguments
        }

        var cloneResult = try await gitAllowingFailure(cloneArguments(includeFilter: true), in: nil, timeout: 180)
        if cloneResult.exitCode != 0 {
            // Retry without the partial-clone filter for servers that reject it.
            if fileManager.fileExists(atPath: clonePath.path) {
                try? fileManager.removeItem(at: clonePath)
            }
            cloneResult = try await gitAllowingFailure(cloneArguments(includeFilter: false), in: nil, timeout: 240)
        }
        guard cloneResult.exitCode == 0 else {
            throw SyncError.cloneFailed(cleanGitError(cloneResult.stderr.isEmpty ? cloneResult.stdout : cloneResult.stderr))
        }

        let resolvedRef = try await trimmedGit(["rev-parse", "--abbrev-ref", "HEAD"], in: clonePath)
        let headCommit = try await trimmedGit(["rev-parse", "HEAD"], in: clonePath)
        return ClonedRepositoryInfo(clonePath: clonePath.path, resolvedRef: resolvedRef, headCommit: headCommit)
    }

    /// List the skills present in an already-cloned repository.
    ///
    /// A `SKILL.md` at the repo root means the whole repository is a single
    /// skill. Otherwise every `SKILL.md`'s parent directory is a skill root,
    /// excluding ones nested inside another skill root (example/reference
    /// skills bundled inside a skill).
    func listSkills(inCloneAt clonePath: URL) async throws -> [RemoteSkillCandidate] {
        let listing = try await git(["ls-tree", "-r", "-z", "HEAD", "--name-only"], in: clonePath)
        let allPaths = listing.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
        let skillFilePaths = allPaths.filter { ($0 as NSString).lastPathComponent == "SKILL.md" }
        guard !skillFilePaths.isEmpty else { return [] }

        if skillFilePaths.contains("SKILL.md") {
            let candidate = try await makeCandidate(directory: "", allPaths: allPaths, clonePath: clonePath)
            return [candidate]
        }

        let skillDirectories = skillFilePaths.map { ($0 as NSString).deletingLastPathComponent }
        var roots: [String] = []
        for directory in skillDirectories.sorted(by: { $0.count < $1.count }) {
            let isNested = roots.contains { directory == $0 || directory.hasPrefix($0 + "/") }
            if !isNested { roots.append(directory) }
        }

        var candidates: [RemoteSkillCandidate] = []
        for directory in roots {
            candidates.append(try await makeCandidate(directory: directory, allPaths: allPaths, clonePath: clonePath))
        }
        return candidates.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func makeCandidate(
        directory: String,
        allPaths: [String],
        clonePath: URL
    ) async throws -> RemoteSkillCandidate {
        let skillFilePath = directory.isEmpty ? "SKILL.md" : directory + "/SKILL.md"
        let rawSkillFile = (try? await git(["show", "HEAD:\(skillFilePath)"], in: clonePath)) ?? ""
        let frontmatter = SkillFrontmatter.parse(rawSkillFile)
        let fallbackName = directory.isEmpty
            ? clonePath.lastPathComponent
            : (directory as NSString).lastPathComponent
        let resolved = SkillFrontmatter.nameAndDescription(fromFrontmatter: frontmatter, fallbackName: fallbackName)

        let referenceFileCount = allPaths.filter { path in
            guard path.hasSuffix(".md"), (path as NSString).lastPathComponent != "SKILL.md" else { return false }
            return directory.isEmpty || path.hasPrefix(directory + "/")
        }.count

        return RemoteSkillCandidate(
            name: resolved.name,
            description: resolved.description,
            repoRelativeDirectory: directory,
            referenceFileCount: referenceFileCount
        )
    }

    // MARK: - Checkout

    /// Materialise the selected skill directories in `clonePath`.
    ///
    /// When the whole repository is the skill, sparse checkout is disabled and
    /// everything is checked out. Otherwise `git sparse-checkout` (cone mode)
    /// pulls each selected directory and the reference files nested inside it.
    /// `additive` adds to an existing sparse set instead of replacing it.
    func checkout(
        _ candidates: [RemoteSkillCandidate],
        inCloneAt clonePath: URL,
        additive: Bool = false
    ) async throws {
        if candidates.contains(where: { $0.isWholeRepository }) {
            _ = try await gitAllowingFailure(["sparse-checkout", "disable"], in: clonePath, timeout: 60)
            _ = try await git(["checkout"], in: clonePath, timeout: 180)
            return
        }

        let directories = candidates.map(\.repoRelativeDirectory).filter { !$0.isEmpty }
        guard !directories.isEmpty else { return }
        let verb = additive ? "add" : "set"
        _ = try await git(["sparse-checkout", verb] + directories, in: clonePath, timeout: 180)
    }

    // MARK: - Updates

    /// Network-only check (`git ls-remote`, no download) for a newer commit.
    func checkForUpdate(
        remoteURL: String,
        ref: String,
        syncedCommit: String
    ) async throws -> SkillRepositoryUpdateStatus {
        let output = try await git(["ls-remote", remoteURL, ref], in: nil, timeout: 45)
        let remoteCommit = output
            .split(separator: "\n").first?
            .split(whereSeparator: { $0 == "\t" || $0 == " " }).first
            .map(String.init)
        guard let remoteCommit, !remoteCommit.isEmpty else {
            throw SyncError.updateCheckFailed("The remote branch “\(ref)” could not be found.")
        }
        return remoteCommit == syncedCommit ? .upToDate : .updateAvailable(remoteCommit: remoteCommit)
    }

    /// Fetch and fast-forward the clone. When the user has edited a skill file
    /// that also changed upstream, the merge is held back and the conflicting
    /// files are returned for the caller to resolve via `resolveConflicts`.
    func update(cloneAt clonePath: URL, ref: String) async throws -> SkillRepositoryUpdateOutcome {
        _ = try await git(["fetch", "origin", ref], in: clonePath, timeout: 180)
        let localHead = try await trimmedGit(["rev-parse", "HEAD"], in: clonePath)
        let remoteCommit = try await trimmedGit(["rev-parse", "origin/\(ref)"], in: clonePath)
        guard localHead != remoteCommit else { return .alreadyUpToDate }

        let dirtyFiles = try await locallyModifiedFiles(in: clonePath)
        let upstreamChanges = try await filesChanged(from: "HEAD", to: "origin/\(ref)", in: clonePath)
        let conflicts = dirtyFiles.intersection(upstreamChanges)

        guard conflicts.isEmpty else {
            return .conflicts(conflicts.sorted().map { SkillRepositoryConflict(repoRelativePath: $0) })
        }

        try await fastForward(to: ref, in: clonePath)
        let newHead = try await trimmedGit(["rev-parse", "HEAD"], in: clonePath)
        return .updated(newCommit: newHead)
    }

    /// Apply an update after the user resolved conflicting files.
    ///
    /// Every conflicting file is reverted to the synced version so the
    /// fast-forward applies cleanly; afterwards the "keep mine" edits are
    /// written back on top, leaving them as in-place modifications again.
    func resolveConflicts(
        cloneAt clonePath: URL,
        ref: String,
        resolutions: [String: SkillConflictResolution]
    ) async throws -> SkillRepositoryUpdateOutcome {
        var keptContent: [String: Data] = [:]
        for (relativePath, resolution) in resolutions {
            if resolution == .keepMine {
                keptContent[relativePath] = try? Data(contentsOf: clonePath.appendingPathComponent(relativePath))
            }
            _ = try await git(["checkout", "HEAD", "--", relativePath], in: clonePath)
        }

        try await fastForward(to: ref, in: clonePath)

        for (relativePath, content) in keptContent {
            try? content.write(to: clonePath.appendingPathComponent(relativePath))
        }

        let newHead = try await trimmedGit(["rev-parse", "HEAD"], in: clonePath)
        return .updated(newCommit: newHead)
    }

    // MARK: - Git helpers

    private func fastForward(to ref: String, in clonePath: URL) async throws {
        let result = try await gitAllowingFailure(["merge", "--ff-only", "origin/\(ref)"], in: clonePath, timeout: 180)
        guard result.exitCode == 0 else {
            throw SyncError.updateFailed(cleanGitError(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
    }

    /// Tracked files with local modifications (worktree or staged).
    private func locallyModifiedFiles(in clonePath: URL) async throws -> Set<String> {
        let worktree = try await git(["diff", "--name-only", "-z"], in: clonePath)
        let staged = try await git(["diff", "--name-only", "-z", "--cached"], in: clonePath)
        let names = (worktree + "\0" + staged).split(separator: "\0").map(String.init)
        return Set(names.filter { !$0.isEmpty })
    }

    private func filesChanged(from: String, to: String, in clonePath: URL) async throws -> Set<String> {
        let output = try await git(["diff", "--name-only", "-z", "\(from)..\(to)"], in: clonePath)
        return Set(output.split(separator: "\0").map(String.init).filter { !$0.isEmpty })
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL?, timeout: TimeInterval = 30) async throws -> String {
        let result = try await gitAllowingFailure(arguments, in: directory, timeout: timeout)
        guard result.exitCode == 0 else {
            throw SyncError.gitCommandFailed(
                command: "git " + arguments.joined(separator: " "),
                message: cleanGitError(result.stderr.isEmpty ? result.stdout : result.stderr)
            )
        }
        return result.stdout
    }

    private func trimmedGit(_ arguments: [String], in directory: URL?, timeout: TimeInterval = 30) async throws -> String {
        try await git(arguments, in: directory, timeout: timeout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gitAllowingFailure(
        _ arguments: [String],
        in directory: URL?,
        timeout: TimeInterval = 30
    ) async throws -> CommandResult {
        try await commandRunner.run(
            "git",
            arguments: ["-c", "core.quotePath=false"] + arguments,
            currentDirectoryURL: directory,
            timeout: timeout,
            environment: gitEnvironment
        )
    }

    private func cleanGitError(_ raw: String) -> String {
        let lines = raw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.suffix(2).joined(separator: " ")
    }
}
