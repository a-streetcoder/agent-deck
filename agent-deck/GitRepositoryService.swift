import Foundation

enum GitMergeOutcome: Hashable {
    case success
    case conflict(status: String)
}

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

    func commit(message: String, description: String = "", in repositoryURL: URL) async throws {
        var arguments = ["commit", "-m", message]
        if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["-m", description]
        }
        try await runGitMutation(arguments: arguments, commandDescription: "git commit", in: repositoryURL)
    }

    func pushCurrentBranch(in repositoryURL: URL) async throws {
        // First try a plain `git push`. If it fails because the current branch has no upstream
        // (common for newly-created session branches), re-run with `-u origin <branch>`.
        let result = try await commandRunner.run(
            "git",
            arguments: ["push"],
            currentDirectoryURL: repositoryURL,
            timeout: 60,
            environment: nil
        )
        if result.exitCode == 0 { return }

        let stderr = result.stderr.lowercased()
        let isMissingUpstream = stderr.contains("no upstream") || stderr.contains("set-upstream") || stderr.contains("has no upstream branch")
        guard isMissingUpstream else {
            throw CommandRunnerError.nonZeroExit(command: "git push", exitCode: result.exitCode, stderr: result.stderr)
        }

        let branch = try await currentBranch(in: repositoryURL)
        try await runGitMutation(
            arguments: ["push", "-u", "origin", branch],
            commandDescription: "git push -u origin \(branch)",
            in: repositoryURL,
            timeout: 60
        )
    }

    func currentBranch(in repositoryURL: URL) async throws -> String {
        let text = try await runText(arguments: ["rev-parse", "--abbrev-ref", "HEAD"], commandDescription: "git rev-parse --abbrev-ref HEAD", in: repositoryURL)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Local branch names (`refs/heads/*`), newest commit first.
    func listLocalBranches(in repositoryURL: URL) async throws -> [String] {
        let text = try await runText(
            arguments: ["for-each-ref", "--format=%(refname:short)", "--sort=-committerdate", "refs/heads/"],
            commandDescription: "git for-each-ref refs/heads",
            in: repositoryURL
        )
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func isClean(in repositoryURL: URL) async throws -> Bool {
        let text = try await runText(arguments: ["status", "--porcelain=v1"], commandDescription: "git status --porcelain=v1", in: repositoryURL)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func hasBranch(_ name: String, in repositoryURL: URL) async throws -> Bool {
        let result = try await commandRunner.run(
            "git",
            arguments: ["show-ref", "--verify", "--quiet", "refs/heads/\(name)"],
            currentDirectoryURL: repositoryURL,
            timeout: 10,
            environment: nil
        )
        return result.exitCode == 0
    }

    func isBranchAhead(_ branch: String, of baseBranch: String, in repositoryURL: URL) async throws -> Bool {
        try await commitsAhead(branch: branch, base: baseBranch, in: repositoryURL) > 0
    }

    func checkoutBranch(_ name: String, in repositoryURL: URL) async throws {
        try await runGitMutation(arguments: ["checkout", name], commandDescription: "git checkout \(name)", in: repositoryURL, timeout: 30)
    }

    func deleteBranch(_ name: String, force: Bool, in repositoryURL: URL) async throws {
        let flag = force ? "-D" : "-d"
        try await runGitMutation(arguments: ["branch", flag, name], commandDescription: "git branch \(flag) \(name)", in: repositoryURL, timeout: 15)
    }

    func commitsAhead(branch: String, base: String, in repositoryURL: URL) async throws -> Int {
        let text = try await runText(
            arguments: ["rev-list", "--count", "\(base)..\(branch)"],
            commandDescription: "git rev-list --count \(base)..\(branch)",
            in: repositoryURL
        )
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    func isAncestor(_ ancestor: String, of descendant: String, in repositoryURL: URL) async throws -> Bool {
        let result = try await commandRunner.run(
            "git",
            arguments: ["merge-base", "--is-ancestor", ancestor, descendant],
            currentDirectoryURL: repositoryURL,
            timeout: 10,
            environment: nil
        )
        return result.exitCode == 0
    }

    func merge(branch: String, in repositoryURL: URL) async throws -> GitMergeOutcome {
        let result = try await commandRunner.run(
            "git",
            arguments: ["merge", "--no-ff", branch],
            currentDirectoryURL: repositoryURL,
            timeout: 60,
            environment: nil
        )
        if result.exitCode == 0 {
            return .success
        }
        // A non-zero exit may mean conflict or some other error. Detect a real merge-in-progress
        // by checking for unmerged paths via `git ls-files --unmerged` — empty output means no
        // conflicts, so the merge failed for some other reason and we throw.
        let unmerged = try await runText(arguments: ["ls-files", "--unmerged"], commandDescription: "git ls-files --unmerged", in: repositoryURL)
        if !unmerged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let statusText = (try? await runText(arguments: ["status", "--short", "--branch"], commandDescription: "git status --short --branch", in: repositoryURL)) ?? unmerged
            return .conflict(status: statusText)
        }
        throw CommandRunnerError.nonZeroExit(command: "git merge --no-ff \(branch)", exitCode: result.exitCode, stderr: result.stderr)
    }

    func statusText(in repositoryURL: URL) async throws -> String {
        try await runText(arguments: ["status", "--short", "--branch"], commandDescription: "git status --short --branch", in: repositoryURL)
    }

    func stagedDiffForCommitMessage(in repositoryURL: URL) async throws -> String {
        let stat = try await runText(arguments: ["diff", "--cached", "--stat"], commandDescription: "git diff --cached --stat", in: repositoryURL)
        let diff = try await runText(arguments: ["diff", "--cached", "--", "."], commandDescription: "git diff --cached", in: repositoryURL)
        return [stat, diff].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
    }

    // MARK: - Release tagging

    func fetch(remote: String, branch: String, in repositoryURL: URL) async throws {
        try await runGitMutation(
            arguments: ["fetch", remote, branch, "--quiet"],
            commandDescription: "git fetch \(remote) \(branch)",
            in: repositoryURL,
            timeout: 60
        )
    }

    func fetchTags(remote: String, in repositoryURL: URL) async throws {
        try await runGitMutation(
            arguments: ["fetch", remote, "--tags", "--quiet"],
            commandDescription: "git fetch \(remote) --tags",
            in: repositoryURL,
            timeout: 60
        )
    }

    /// The highest `v<MAJOR>.<MINOR>[.<PATCH>]` tag, or nil when the repo has none.
    func latestVersionTag(in repositoryURL: URL) async throws -> String? {
        let text = try await runText(
            arguments: ["tag", "-l", "v*.*", "--sort=-v:refname"],
            commandDescription: "git tag -l v*.* --sort=-v:refname",
            in: repositoryURL
        )
        return text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    func localTagExists(_ tag: String, in repositoryURL: URL) async throws -> Bool {
        let result = try await commandRunner.run(
            "git",
            arguments: ["rev-parse", "--verify", "--quiet", "refs/tags/\(tag)"],
            currentDirectoryURL: repositoryURL,
            timeout: 10,
            environment: nil
        )
        return result.exitCode == 0
    }

    func remoteTagExists(_ tag: String, remote: String, in repositoryURL: URL) async throws -> Bool {
        let text = try await runText(
            arguments: ["ls-remote", "--tags", remote, tag],
            commandDescription: "git ls-remote --tags \(remote) \(tag)",
            in: repositoryURL,
            timeout: 30
        )
        return text.contains("refs/tags/\(tag)")
    }

    /// Commit subjects (newest first) for the range that this release will cover:
    /// everything since `sinceTag`, or the most recent commits when the repo has
    /// no prior version tag. Merge commits are excluded. Used to feed the AI
    /// release-notes writer.
    func commitSubjects(sinceTag: String?, in repositoryURL: URL, limit: Int = 200) async throws -> [String] {
        var arguments = ["log", "--no-merges", "--pretty=format:%s"]
        if let sinceTag, !sinceTag.isEmpty {
            arguments.append("\(sinceTag)..HEAD")
        } else {
            arguments.append("--max-count=\(limit)")
        }
        let text = try await runText(
            arguments: arguments,
            commandDescription: "git log \(sinceTag.map { "\($0)..HEAD" } ?? "--max-count=\(limit)")",
            in: repositoryURL,
            timeout: 30
        )
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func createAnnotatedTag(_ tag: String, message: String, in repositoryURL: URL) async throws {
        // --cleanup=verbatim keeps the message exactly as written. Without it,
        // git tag defaults to `strip`, which deletes lines beginning with `#`
        // (treating them as comments) — that would silently drop markdown
        // headings like "### New features" from AI-drafted release notes.
        try await runGitMutation(
            arguments: ["tag", "-a", "--cleanup=verbatim", tag, "-m", message],
            commandDescription: "git tag -a \(tag)",
            in: repositoryURL
        )
    }

    func pushTag(_ tag: String, remote: String, in repositoryURL: URL) async throws {
        try await runGitMutation(
            arguments: ["push", remote, tag],
            commandDescription: "git push \(remote) \(tag)",
            in: repositoryURL,
            timeout: 60
        )
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

    private func runText(arguments: [String], commandDescription: String, in repositoryURL: URL, timeout: TimeInterval = 15) async throws -> String {
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
        return result.stdout
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
