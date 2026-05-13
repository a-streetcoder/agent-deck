import XCTest
@testable import agent_deck

final class PiSubagentWorktreeServiceTests: XCTestCase {
    @MainActor
    func testPreparePatchWritesBinaryDiffAndListsChangedFiles() async throws {
        let context = try makeWorktreeContext()
        let diff = """
        diff --git a/README.md b/README.md
        index 1111111..2222222 100644
        --- a/README.md
        +++ b/README.md
        @@ -1 +1 @@
        -old
        +new
        diff --git a/agent-deck/AppViewModel.swift b/agent-deck/AppViewModel.swift
        index 3333333..4444444 100644
        --- a/agent-deck/AppViewModel.swift
        +++ b/agent-deck/AppViewModel.swift
        @@ -1 +1 @@
        -old
        +new
        """
        let runner = FakeWorktreeCommandRunner { invocation in
            if invocation.arguments == ["add", "-N", "."] {
                return CommandResult(stdout: "", stderr: "", exitCode: 0)
            } else if invocation.arguments == ["diff", "--binary", "HEAD"] {
                return CommandResult(stdout: diff, stderr: "", exitCode: 0)
            } else {
                XCTFail("Unexpected git invocation: \(invocation.arguments)")
                return CommandResult(stdout: "", stderr: "", exitCode: 1)
            }
        }

        let service = PiSubagentWorktreeService(commandRunner: runner)
        let patch = try await service.preparePatch(for: context.run)

        XCTAssertEqual(patch.changedFiles, ["README.md", "agent-deck/AppViewModel.swift"])
        XCTAssertEqual(try String(contentsOfFile: patch.patchPath, encoding: .utf8), diff)
        let arguments = await runner.arguments
        XCTAssertEqual(arguments, [
            ["add", "-N", "."],
            ["diff", "--binary", "HEAD"]
        ])
    }

    @MainActor
    func testApplyPatchRefusesWhenParentRepositoryIsDirty() async throws {
        let context = try makeWorktreeContext()
        let runner = FakeWorktreeCommandRunner { invocation in
            XCTAssertEqual(invocation.arguments, ["status", "--porcelain=v1"])
            return CommandResult(stdout: " M README.md\n", stderr: "", exitCode: 0)
        }
        let service = PiSubagentWorktreeService(commandRunner: runner)

        do {
            _ = try await service.applyPatch(for: context.run)
            XCTFail("Expected dirty parent repository to be rejected")
        } catch PiSubagentWorktreeError.parentRepositoryDirty(let status) {
            XCTAssertEqual(status, " M README.md\n")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testWorktreeOperationsRejectPathsOutsideArtifactDirectory() async throws {
        let artifact = try PiTestSupport.temporaryProjectURL()
        let outsideWorktree = try PiTestSupport.temporaryProjectURL()
        let parent = try PiTestSupport.temporaryProjectURL()
        let run = makeRun(artifactDirectory: artifact, worktree: outsideWorktree, parent: parent)
        let service = PiSubagentWorktreeService(commandRunner: FakeWorktreeCommandRunner.neverCalled)

        do {
            _ = try await service.preparePatch(for: run)
            XCTFail("Expected unsafe worktree path to be rejected")
        } catch PiSubagentWorktreeError.unsafePath(let path) {
            XCTAssertEqual(path, outsideWorktree.path)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testNonIsolatedRunsCannotPrepareWorktreePatches() async throws {
        let artifact = try PiTestSupport.temporaryProjectURL()
        let worktree = try PiTestSupport.temporaryProjectURL()
        let parent = try PiTestSupport.temporaryProjectURL()
        var run = makeRun(artifactDirectory: artifact, worktree: worktree, parent: parent)
        run.isWorktreeIsolated = false
        let service = PiSubagentWorktreeService(commandRunner: FakeWorktreeCommandRunner.neverCalled)

        do {
            _ = try await service.preparePatch(for: run)
            XCTFail("Expected non-isolated run to be rejected")
        } catch PiSubagentWorktreeError.notIsolated {
            XCTAssertTrue(true)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    private func makeWorktreeContext() throws -> (run: PiSubagentRunRecord, artifact: URL, worktree: URL, parent: URL) {
        let artifact = try PiTestSupport.temporaryProjectURL()
        let worktree = artifact.appendingPathComponent("worktree", isDirectory: true)
        let parent = try PiTestSupport.temporaryProjectURL()
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        return (makeRun(artifactDirectory: artifact, worktree: worktree, parent: parent), artifact, worktree, parent)
    }

    @MainActor
    private func makeRun(artifactDirectory: URL, worktree: URL, parent: URL) -> PiSubagentRunRecord {
        let now = Date()
        return PiSubagentRunRecord(
            id: UUID(),
            parentSessionID: UUID(),
            mode: .single,
            status: .completed,
            agentName: "coder",
            task: "Patch files",
            model: "zai/glm-5.1",
            thinking: nil,
            expectedOutcome: .editFilesInWorktree,
            requestedOutputPath: nil,
            allowOverwrite: nil,
            readFirstPaths: nil,
            tools: [],
            skills: [],
            concurrencyLimit: nil,
            worktreePolicy: "isolated",
            aggregateSummary: nil,
            artifactDirectory: artifactDirectory.path,
            outputPath: artifactDirectory.appendingPathComponent("output.md").path,
            worktreePath: worktree.path,
            parentRepoPath: parent.path,
            baseCommit: "abc123",
            isWorktreeIsolated: true,
            worktreeStatus: .active,
            worktreePatchPath: nil,
            childSessionID: nil,
            childPiSessionFile: nil,
            launchCommand: nil,
            summary: nil,
            error: nil,
            child: nil,
            children: nil,
            graphEdges: nil,
            createdAt: now,
            updatedAt: now,
            completedAt: now,
            durationMs: 1
        )
    }
}

private struct FakeGitInvocation: Sendable, Equatable {
    let command: String
    let arguments: [String]
    let currentDirectoryURL: URL?
}

private actor FakeWorktreeCommandRunner: CommandRunning {
    static let neverCalled = FakeWorktreeCommandRunner { invocation in
        XCTFail("Unexpected git invocation: \(invocation.arguments)")
        return CommandResult(stdout: "", stderr: "", exitCode: 1)
    }

    private var recordedArguments: [[String]] = []
    private let handler: @Sendable (FakeGitInvocation) async throws -> CommandResult

    init(handler: @escaping @Sendable (FakeGitInvocation) async throws -> CommandResult) {
        self.handler = handler
    }

    var arguments: [[String]] {
        recordedArguments
    }

    func run(
        _ command: String,
        arguments: [String],
        currentDirectoryURL: URL?,
        timeout: TimeInterval?,
        environment: [String: String]?
    ) async throws -> CommandResult {
        recordedArguments.append(arguments)
        return try await handler(FakeGitInvocation(command: command, arguments: arguments, currentDirectoryURL: currentDirectoryURL))
    }
}
