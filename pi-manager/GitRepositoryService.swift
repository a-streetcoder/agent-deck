import Foundation

struct GitRepositoryService {
    private let commandRunner: CommandRunning

    init(commandRunner: CommandRunning = CommandRunner()) {
        self.commandRunner = commandRunner
    }

    func loadChanges(in repositoryURL: URL) async throws -> RepositoryChangesSnapshot {
        let statusResult = try await commandRunner.run(
            "git",
            arguments: ["status", "--porcelain=v1", "-z", "-b"],
            currentDirectoryURL: repositoryURL,
            timeout: 15,
            environment: nil
        )

        guard statusResult.exitCode == 0 else {
            throw CommandRunnerError.nonZeroExit(command: "git status --porcelain=v1 -b", exitCode: statusResult.exitCode, stderr: statusResult.stderr)
        }

        return parseStatus(statusResult.stdout)
    }

    func loadDiff(for filePath: String, kind: GitDiffKind, in repositoryURL: URL) async throws -> String {
        switch kind {
        case .staged:
            return try await runDiff(arguments: ["diff", "--cached", "--", filePath], commandDescription: "git diff --cached -- \(filePath)", in: repositoryURL)
        case .unstaged, .conflicted:
            return try await runDiff(arguments: ["diff", "--", filePath], commandDescription: "git diff -- \(filePath)", in: repositoryURL)
        case .untracked:
            return try await loadUntrackedDiff(for: filePath, in: repositoryURL)
        }
    }

    func stage(_ filePath: String, in repositoryURL: URL) async throws {
        try await runGitMutation(arguments: ["add", "--", filePath], commandDescription: "git add -- \(filePath)", in: repositoryURL)
    }

    func unstage(_ filePath: String, in repositoryURL: URL) async throws {
        try await runGitMutation(arguments: ["restore", "--staged", "--", filePath], commandDescription: "git restore --staged -- \(filePath)", in: repositoryURL)
    }

    func stageAll(in repositoryURL: URL) async throws {
        try await runGitMutation(arguments: ["add", "-A"], commandDescription: "git add -A", in: repositoryURL)
    }

    func unstageAll(in repositoryURL: URL) async throws {
        try await runGitMutation(arguments: ["restore", "--staged", "."], commandDescription: "git restore --staged .", in: repositoryURL)
    }

    func commit(message: String, in repositoryURL: URL) async throws {
        try await runGitMutation(arguments: ["commit", "-m", message], commandDescription: "git commit -m", in: repositoryURL)
    }

    func pushCurrentBranch(in repositoryURL: URL) async throws {
        try await runGitMutation(arguments: ["push"], commandDescription: "git push", in: repositoryURL, timeout: 60)
    }

    private func runDiff(arguments: [String], commandDescription: String, in repositoryURL: URL) async throws -> String {
        let diffResult = try await commandRunner.run(
            "git",
            arguments: arguments,
            currentDirectoryURL: repositoryURL,
            timeout: 15,
            environment: nil
        )

        guard diffResult.exitCode == 0 else {
            throw CommandRunnerError.nonZeroExit(command: commandDescription, exitCode: diffResult.exitCode, stderr: diffResult.stderr)
        }

        return diffResult.stdout
    }

    private func loadUntrackedDiff(for filePath: String, in repositoryURL: URL) async throws -> String {
        let diffResult = try await commandRunner.run(
            "git",
            arguments: ["diff", "--no-index", "--", "/dev/null", filePath],
            currentDirectoryURL: repositoryURL,
            timeout: 15,
            environment: nil
        )

        // git diff --no-index exits with 1 when it successfully found differences.
        guard diffResult.exitCode == 0 || diffResult.exitCode == 1 else {
            return try loadUntrackedPreview(for: filePath, in: repositoryURL)
        }

        return diffResult.stdout.isEmpty ? try loadUntrackedPreview(for: filePath, in: repositoryURL) : diffResult.stdout
    }

    private func runGitMutation(arguments: [String], commandDescription: String, in repositoryURL: URL, timeout: TimeInterval = 15) async throws {
        let result = try await commandRunner.run(
            "git",
            arguments: arguments,
            currentDirectoryURL: repositoryURL,
            timeout: timeout,
            environment: nil
        )

        guard result.exitCode == 0 else {
            throw CommandRunnerError.nonZeroExit(command: commandDescription, exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    private func loadUntrackedPreview(for filePath: String, in repositoryURL: URL) throws -> String {
        let url = repositoryURL.appendingPathComponent(filePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Untracked file. Binary or unreadable preview.\n\n\(filePath)"
        }

        if text.count > 12_000 {
            let prefix = String(text.prefix(12_000))
            return "Untracked file preview (truncated).\n\n\(prefix)"
        }

        return "Untracked file preview.\n\n\(text)"
    }

    private func parseStatus(_ text: String) -> RepositoryChangesSnapshot {
        let records = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        let branchLine = records.first(where: { $0.hasPrefix("## ") }) ?? "## HEAD"
        let branchSummary = parseBranchSummary(branchLine)

        var staged: [RepositoryFileChange] = []
        var unstaged: [RepositoryFileChange] = []
        var untracked: [RepositoryFileChange] = []
        var conflicted: [RepositoryFileChange] = []

        var index = branchLine == records.first ? 1 : 0
        while index < records.count {
            let record = records[index]
            guard record.count >= 3 else {
                index += 1
                continue
            }

            let indexStatus = record[record.startIndex]
            let worktreeStatus = record[record.index(after: record.startIndex)]
            let pathStart = record.index(record.startIndex, offsetBy: 3)
            let path = String(record[pathStart...])
            let change = RepositoryFileChange(path: path, indexStatus: indexStatus, worktreeStatus: worktreeStatus)

            if change.isConflicted {
                conflicted.append(change)
            } else if change.isUntracked {
                untracked.append(change)
            } else {
                if change.hasIndexChanges { staged.append(change) }
                if change.hasWorktreeChanges { unstaged.append(change) }
            }

            index += 1
            if usesTwoPathRecord(indexStatus: indexStatus, worktreeStatus: worktreeStatus), index < records.count {
                index += 1
            }
        }

        return RepositoryChangesSnapshot(
            branchName: branchSummary.branchName,
            upstreamBranch: branchSummary.upstreamBranch,
            aheadCount: branchSummary.aheadCount,
            behindCount: branchSummary.behindCount,
            staged: staged.sorted(by: byPath),
            unstaged: unstaged.sorted(by: byPath),
            untracked: untracked.sorted(by: byPath),
            conflicted: conflicted.sorted(by: byPath)
        )
    }

    private func parseBranchSummary(_ line: String) -> (branchName: String, upstreamBranch: String?, aheadCount: Int, behindCount: Int) {
        let summary = line.replacingOccurrences(of: "## ", with: "")
        let trackingSummary = summary.components(separatedBy: " [").first ?? summary

        let branchName: String
        let upstreamBranch: String?
        if let range = trackingSummary.range(of: "...") {
            branchName = String(trackingSummary[..<range.lowerBound])
            let upstream = String(trackingSummary[range.upperBound...])
            upstreamBranch = upstream.isEmpty ? nil : upstream
        } else {
            branchName = trackingSummary
            upstreamBranch = nil
        }

        let aheadCount = extractCount(label: "ahead", from: summary)
        let behindCount = extractCount(label: "behind", from: summary)

        return (branchName.isEmpty ? "HEAD" : branchName, upstreamBranch, aheadCount, behindCount)
    }

    private func extractCount(label: String, from summary: String) -> Int {
        guard let range = summary.range(of: "\(label) ", options: .literal) else { return 0 }
        let rest = summary[range.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        return Int(digits) ?? 0
    }

    private func usesTwoPathRecord(indexStatus: Character, worktreeStatus: Character) -> Bool {
        [indexStatus, worktreeStatus].contains("R") || [indexStatus, worktreeStatus].contains("C")
    }

    private func byPath(_ lhs: RepositoryFileChange, _ rhs: RepositoryFileChange) -> Bool {
        lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
    }
}
