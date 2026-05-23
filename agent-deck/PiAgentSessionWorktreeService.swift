import Foundation

enum PiAgentSessionWorktreeError: LocalizedError {
    case notAGitRepository(String)
    case detachedHead
    case worktreeFailed(String)
    case branchNameUnavailable(String)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case let .notAGitRepository(path):
            return "The project at \(path) is not a git repository."
        case .detachedHead:
            return "The project is on a detached HEAD. Switch to a branch before starting a worktree-isolated session."
        case let .worktreeFailed(detail):
            return "git worktree command failed: \(detail)"
        case let .branchNameUnavailable(name):
            return "Could not find a free branch name starting with \(name)."
        case let .unsafePath(path):
            return "Refusing to operate on an unsafe worktree path: \(path)"
        }
    }
}

struct PiAgentSessionWorktreeCreation: Hashable {
    let worktreePath: String
    let branchName: String
    let sourceBranch: String
}

struct PiAgentSessionWorktreeService {
    private let commandRunner: CommandRunning
    private let fileManager: FileManager

    init(commandRunner: CommandRunning = CommandRunner(), fileManager: FileManager = .default) {
        self.commandRunner = commandRunner
        self.fileManager = fileManager
    }

    func createWorktree(for sessionID: UUID, projectURL: URL) async throws -> PiAgentSessionWorktreeCreation {
        let sourceBranch = try await readCurrentBranch(in: projectURL)
        guard sourceBranch != "HEAD" else { throw PiAgentSessionWorktreeError.detachedHead }

        let root = try worktreesRoot()
        let targetURL = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try? fileManager.removeItem(at: targetURL) // tolerate leftovers from a previous failed attempt
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let baseName = "agent-deck/session-\(sessionID.uuidString.prefix(8).lowercased())"
        let branchName = try await uniqueBranchName(baseName: baseName, in: projectURL)

        let result = try await commandRunner.run(
            "git",
            arguments: ["-C", projectURL.path, "worktree", "add", "-b", branchName, targetURL.path, sourceBranch],
            currentDirectoryURL: nil,
            timeout: 60,
            environment: nil
        )
        guard result.exitCode == 0 else {
            try? fileManager.removeItem(at: targetURL)
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PiAgentSessionWorktreeError.worktreeFailed(detail.isEmpty ? "git worktree add failed" : detail)
        }

        return PiAgentSessionWorktreeCreation(
            worktreePath: targetURL.path,
            branchName: branchName,
            sourceBranch: sourceBranch
        )
    }

    func removeWorktree(worktreePath: String, projectURL: URL, branchName: String?, deleteBranch: Bool) async throws {
        let root = try worktreesRoot()
        let worktreeURL = URL(fileURLWithPath: worktreePath).standardizedFileURL
        guard isDescendant(worktreeURL, of: root) else { throw PiAgentSessionWorktreeError.unsafePath(worktreePath) }

        // Best-effort: `git worktree remove` may fail if the path is already gone or the
        // worktree is locked. Tolerate non-zero exit codes; prune at the end cleans up.
        _ = try? await commandRunner.run(
            "git",
            arguments: ["-C", projectURL.path, "worktree", "remove", "--force", worktreeURL.path],
            currentDirectoryURL: nil,
            timeout: 60,
            environment: nil
        )

        _ = try? await commandRunner.run(
            "git",
            arguments: ["-C", projectURL.path, "worktree", "prune"],
            currentDirectoryURL: nil,
            timeout: 30,
            environment: nil
        )

        // If the on-disk path is still there, remove it manually.
        if fileManager.fileExists(atPath: worktreeURL.path) {
            try? fileManager.removeItem(at: worktreeURL)
        }

        if deleteBranch, let branchName, !branchName.isEmpty {
            _ = try? await commandRunner.run(
                "git",
                arguments: ["-C", projectURL.path, "branch", "-D", branchName],
                currentDirectoryURL: nil,
                timeout: 15,
                environment: nil
            )
        }
    }

    func worktreesRoot() throws -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let root = appSupport
            .appendingPathComponent(AppBrand.displayName, isDirectory: true)
            .appendingPathComponent("Session Worktrees", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root.standardizedFileURL
    }

    private func readCurrentBranch(in projectURL: URL) async throws -> String {
        let result = try await commandRunner.run(
            "git",
            arguments: ["-C", projectURL.path, "rev-parse", "--abbrev-ref", "HEAD"],
            currentDirectoryURL: nil,
            timeout: 10,
            environment: nil
        )
        guard result.exitCode == 0 else {
            throw PiAgentSessionWorktreeError.notAGitRepository(projectURL.path)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func uniqueBranchName(baseName: String, in projectURL: URL) async throws -> String {
        for attempt in 0..<50 {
            let candidate = attempt == 0 ? baseName : "\(baseName)-\(attempt + 1)"
            let result = try await commandRunner.run(
                "git",
                arguments: ["-C", projectURL.path, "show-ref", "--verify", "--quiet", "refs/heads/\(candidate)"],
                currentDirectoryURL: nil,
                timeout: 10,
                environment: nil
            )
            if result.exitCode != 0 { return candidate }
        }
        throw PiAgentSessionWorktreeError.branchNameUnavailable(baseName)
    }

    private func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let childPath = child.path.hasSuffix("/") ? child.path : child.path + "/"
        let parentPath = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return childPath.hasPrefix(parentPath)
    }
}
