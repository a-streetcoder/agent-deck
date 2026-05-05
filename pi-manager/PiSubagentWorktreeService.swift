import Foundation

struct PiSubagentWorktreePatch: Hashable {
    let patchPath: String
    let patch: String
    let changedFiles: [String]
}

enum PiSubagentWorktreeError: LocalizedError {
    case notIsolated
    case missingPath
    case unsafePath(String)
    case parentRepositoryDirty(String)
    case emptyPatch

    var errorDescription: String? {
        switch self {
        case .notIsolated:
            return "This run does not have an app-managed isolated worktree."
        case .missingPath:
            return "The run is missing its worktree or parent repository path."
        case let .unsafePath(path):
            return "Refusing to operate on an unsafe worktree path: \(path)"
        case let .parentRepositoryDirty(status):
            return "Refusing to apply while the parent repository has uncommitted changes. Commit, stash, or discard them first.\n\n\(status)"
        case .emptyPatch:
            return "The isolated worktree has no changes to apply."
        }
    }
}

struct PiSubagentWorktreeService {
    private let commandRunner: CommandRunning
    private let fileManager: FileManager

    init(commandRunner: CommandRunning = CommandRunner(), fileManager: FileManager = .default) {
        self.commandRunner = commandRunner
        self.fileManager = fileManager
    }

    func preparePatch(for run: PiSubagentRunRecord) async throws -> PiSubagentWorktreePatch {
        let context = try validatedContext(for: run)
        _ = try await runGit(["add", "-N", "."], in: context.worktreeURL, timeout: 30, allowExitCodes: [0])
        let diff = try await runGit(["diff", "--binary", "HEAD"], in: context.worktreeURL, timeout: 30, allowExitCodes: [0]).stdout
        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PiSubagentWorktreeError.emptyPatch }
        let patchURL = context.artifactURL.appendingPathComponent("worktree.patch")
        try diff.write(to: patchURL, atomically: true, encoding: .utf8)
        return PiSubagentWorktreePatch(patchPath: patchURL.path, patch: diff, changedFiles: changedFiles(from: diff))
    }

    func applyPatch(for run: PiSubagentRunRecord) async throws -> PiSubagentWorktreePatch {
        let context = try validatedContext(for: run)
        let parentStatus = try await runGit(["status", "--porcelain=v1"], in: context.parentURL, timeout: 15, allowExitCodes: [0]).stdout
        guard parentStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PiSubagentWorktreeError.parentRepositoryDirty(parentStatus)
        }
        let patch = try await preparePatch(for: run)
        _ = try await runGit(["apply", "--check", "--3way", "--binary", patch.patchPath], in: context.parentURL, timeout: 30, allowExitCodes: [0])
        _ = try await runGit(["apply", "--3way", "--binary", patch.patchPath], in: context.parentURL, timeout: 60, allowExitCodes: [0])
        return patch
    }

    func discardWorktree(for run: PiSubagentRunRecord) async throws {
        let context = try validatedContext(for: run)
        _ = try await runGit(["worktree", "remove", "--force", context.worktreeURL.path], in: context.parentURL, timeout: 60, allowExitCodes: [0])
        _ = try? await runGit(["worktree", "prune"], in: context.parentURL, timeout: 30, allowExitCodes: [0])
    }

    private func validatedContext(for run: PiSubagentRunRecord) throws -> WorktreeContext {
        guard run.isWorktreeIsolated == true else { throw PiSubagentWorktreeError.notIsolated }
        guard let worktreePath = run.worktreePath, let parentRepoPath = run.parentRepoPath else { throw PiSubagentWorktreeError.missingPath }
        let artifactURL = URL(fileURLWithPath: run.artifactDirectory).standardizedFileURL
        let worktreeURL = URL(fileURLWithPath: worktreePath).standardizedFileURL
        let parentURL = URL(fileURLWithPath: parentRepoPath).standardizedFileURL
        guard isDescendant(worktreeURL, of: artifactURL) else { throw PiSubagentWorktreeError.unsafePath(worktreePath) }
        guard fileManager.fileExists(atPath: worktreeURL.path) else { throw PiSubagentWorktreeError.missingPath }
        return WorktreeContext(artifactURL: artifactURL, worktreeURL: worktreeURL, parentURL: parentURL)
    }

    private func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let childPath = child.path.hasSuffix("/") ? child.path : child.path + "/"
        let parentPath = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return childPath.hasPrefix(parentPath)
    }

    private func runGit(_ arguments: [String], in directory: URL, timeout: TimeInterval, allowExitCodes: Set<Int32>) async throws -> CommandResult {
        let result = try await commandRunner.run("git", arguments: arguments, currentDirectoryURL: directory, timeout: timeout, environment: nil)
        guard allowExitCodes.contains(result.exitCode) else {
            throw CommandRunnerError.nonZeroExit(command: "git \(arguments.joined(separator: " "))", exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }

    private func changedFiles(from patch: String) -> [String] {
        patch.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("diff --git a/") else { return nil }
            let parts = line.split(separator: " ")
            guard parts.count >= 4 else { return nil }
            let bPath = String(parts[3])
            guard bPath.hasPrefix("b/") else { return nil }
            return String(bPath.dropFirst(2))
        }
    }

    private struct WorktreeContext {
        let artifactURL: URL
        let worktreeURL: URL
        let parentURL: URL
    }
}
