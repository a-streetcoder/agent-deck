import XCTest
@testable import agent_deck

@MainActor
final class SkillRepositorySyncServiceTests: XCTestCase {

    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        for url in tempRoots {
            try? FileManager.default.removeItem(at: url)
        }
        tempRoots.removeAll()
    }

    // MARK: - Source resolution

    func testResolvesGitHubURL() throws {
        let source = try SkillRepositorySyncService.resolveSource(from: "https://github.com/dimillian/skills")
        XCTAssertEqual(source.owner, "dimillian")
        XCTAssertEqual(source.repo, "skills")
        XCTAssertEqual(source.remoteURL, "https://github.com/dimillian/skills.git")
        XCTAssertNil(source.ref)
        XCTAssertNil(source.preselectedSkillSlug)
    }

    func testResolvesGitHubURLWithDotGitStripped() throws {
        let source = try SkillRepositorySyncService.resolveSource(from: "https://github.com/ebuntario/apple-hig.git")
        XCTAssertEqual(source.repo, "apple-hig")
        XCTAssertEqual(source.remoteURL, "https://github.com/ebuntario/apple-hig.git")
    }

    func testResolvesShorthand() throws {
        let source = try SkillRepositorySyncService.resolveSource(from: "ebuntario/apple-hig")
        XCTAssertEqual(source.owner, "ebuntario")
        XCTAssertEqual(source.repo, "apple-hig")
        XCTAssertEqual(source.remoteURL, "https://github.com/ebuntario/apple-hig.git")
    }

    func testResolvesHostPrefixedURLWithoutScheme() throws {
        let source = try SkillRepositorySyncService.resolveSource(from: "github.com/dimillian/skills")
        XCTAssertEqual(source.owner, "dimillian")
        XCTAssertEqual(source.repo, "skills")
        XCTAssertEqual(source.remoteURL, "https://github.com/dimillian/skills.git")
    }

    func testResolvesSkillsShDeepLink() throws {
        let source = try SkillRepositorySyncService.resolveSource(
            from: "https://www.skills.sh/dimillian/skills/swiftui-liquid-glass"
        )
        XCTAssertEqual(source.owner, "dimillian")
        XCTAssertEqual(source.repo, "skills")
        XCTAssertEqual(source.remoteURL, "https://github.com/dimillian/skills.git")
        XCTAssertEqual(source.preselectedSkillSlug, "swiftui-liquid-glass")
    }

    func testResolvesTreeURLWithBranchAndPath() throws {
        let source = try SkillRepositorySyncService.resolveSource(
            from: "https://github.com/owner/repo/tree/dev/skills/foo"
        )
        XCTAssertEqual(source.ref, "dev")
        XCTAssertEqual(source.preselectedSkillSlug, "skills/foo")
    }

    func testResolvesSSHRemote() throws {
        let source = try SkillRepositorySyncService.resolveSource(from: "git@github.com:owner/repo.git")
        XCTAssertEqual(source.owner, "owner")
        XCTAssertEqual(source.repo, "repo")
        XCTAssertEqual(source.remoteURL, "https://github.com/owner/repo.git")
    }

    func testResolvesSkillsShReservedPathRejected() throws {
        // skills.sh/docs is a docs page, not an owner/repo pair.
        XCTAssertThrowsError(try SkillRepositorySyncService.resolveSource(from: "https://skills.sh/docs/cli"))
    }

    func testResolveRejectsEmptyAndGarbage() {
        XCTAssertThrowsError(try SkillRepositorySyncService.resolveSource(from: "   "))
        XCTAssertThrowsError(try SkillRepositorySyncService.resolveSource(from: "not a url"))
    }

    // MARK: - Clone / discover / checkout against a local origin

    func testClonesDiscoversAndSparseChecksOutSelectedSkills() async throws {
        let origin = try makeOriginRepository(
            skills: [
                "skills/alpha": "Alpha Skill",
                "skills/beta": "Beta Skill",
            ],
            referenceFiles: ["skills/alpha/references/usage.md": "# Usage"]
        )
        let service = SkillRepositorySyncService()
        let clonePath = try makeTempURL()

        let source = RemoteSkillSource(remoteURL: origin.path, owner: "acme", repo: "kit", ref: nil, preselectedSkillSlug: nil)
        let info = try await service.cloneForDiscovery(source, into: clonePath)
        XCTAssertEqual(info.resolvedRef, "main")
        XCTAssertFalse(info.headCommit.isEmpty)

        let candidates = try await service.listSkills(inCloneAt: clonePath)
        XCTAssertEqual(candidates.map(\.name), ["Alpha Skill", "Beta Skill"])
        let alpha = try XCTUnwrap(candidates.first { $0.name == "Alpha Skill" })
        XCTAssertEqual(alpha.repoRelativeDirectory, "skills/alpha")
        XCTAssertEqual(alpha.referenceFileCount, 1, "Reference markdown inside the skill folder is counted.")

        try await service.checkout([alpha], inCloneAt: clonePath)

        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(atPath: clonePath.appendingPathComponent("skills/alpha/SKILL.md").path))
        XCTAssertTrue(
            fileManager.fileExists(atPath: clonePath.appendingPathComponent("skills/alpha/references/usage.md").path),
            "Reference files nested in the skill folder are checked out with it."
        )
        XCTAssertFalse(
            fileManager.fileExists(atPath: clonePath.appendingPathComponent("skills/beta/SKILL.md").path),
            "Unselected skills are not materialised by the sparse checkout."
        )
    }

    func testWholeRepositorySkillCheckedOutEntirely() async throws {
        let origin = try makeOriginRepository(
            skills: ["": "Root Skill"],
            referenceFiles: ["references/notes.md": "# Notes"]
        )
        let service = SkillRepositorySyncService()
        let clonePath = try makeTempURL()

        let source = RemoteSkillSource(remoteURL: origin.path, owner: "acme", repo: "hig", ref: nil, preselectedSkillSlug: nil)
        _ = try await service.cloneForDiscovery(source, into: clonePath)

        let candidates = try await service.listSkills(inCloneAt: clonePath)
        XCTAssertEqual(candidates.count, 1)
        let root = try XCTUnwrap(candidates.first)
        XCTAssertTrue(root.isWholeRepository)

        try await service.checkout([root], inCloneAt: clonePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clonePath.appendingPathComponent("references/notes.md").path))
    }

    func testUpdateFastForwardsWhenNoLocalEdits() async throws {
        let origin = try makeOriginRepository(skills: ["skills/alpha": "Alpha Skill"], referenceFiles: [:])
        let service = SkillRepositorySyncService()
        let clonePath = try makeTempURL()
        let source = RemoteSkillSource(remoteURL: origin.path, owner: "acme", repo: "kit", ref: nil, preselectedSkillSlug: nil)
        _ = try await service.cloneForDiscovery(source, into: clonePath)
        let candidates = try await service.listSkills(inCloneAt: clonePath)
        try await service.checkout(candidates, inCloneAt: clonePath)

        try commitChange(in: origin, path: "skills/alpha/SKILL.md", contents: skillFile(name: "Alpha Skill", body: "Updated."))

        let outcome = try await service.update(cloneAt: clonePath, ref: "main")
        guard case .updated = outcome else {
            return XCTFail("Expected a clean fast-forward, got \(outcome).")
        }
        let updated = try String(contentsOf: clonePath.appendingPathComponent("skills/alpha/SKILL.md"), encoding: .utf8)
        XCTAssertTrue(updated.contains("Updated."))
    }

    func testUpdateReportsConflictThenKeepsMineOnResolve() async throws {
        let origin = try makeOriginRepository(skills: ["skills/alpha": "Alpha Skill"], referenceFiles: [:])
        let service = SkillRepositorySyncService()
        let clonePath = try makeTempURL()
        let source = RemoteSkillSource(remoteURL: origin.path, owner: "acme", repo: "kit", ref: nil, preselectedSkillSlug: nil)
        _ = try await service.cloneForDiscovery(source, into: clonePath)
        let candidates = try await service.listSkills(inCloneAt: clonePath)
        try await service.checkout(candidates, inCloneAt: clonePath)

        // Local in-place edit.
        let localFile = clonePath.appendingPathComponent("skills/alpha/SKILL.md")
        try skillFile(name: "Alpha Skill", body: "My local edit.").write(to: localFile, atomically: true, encoding: .utf8)
        // Conflicting upstream edit to the same file.
        try commitChange(in: origin, path: "skills/alpha/SKILL.md", contents: skillFile(name: "Alpha Skill", body: "Upstream edit."))

        let outcome = try await service.update(cloneAt: clonePath, ref: "main")
        guard case let .conflicts(conflicts) = outcome else {
            return XCTFail("Expected a conflict, got \(outcome).")
        }
        XCTAssertEqual(conflicts.map(\.repoRelativePath), ["skills/alpha/SKILL.md"])

        let resolved = try await service.resolveConflicts(
            cloneAt: clonePath,
            ref: "main",
            resolutions: ["skills/alpha/SKILL.md": .keepMine]
        )
        guard case .updated = resolved else {
            return XCTFail("Expected the resolved update to apply, got \(resolved).")
        }
        let finalContents = try String(contentsOf: localFile, encoding: .utf8)
        XCTAssertTrue(finalContents.contains("My local edit."), "Keep Mine preserves the local edit.")
    }

    // MARK: - Local origin helpers

    private func makeTempURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillRepoSyncTests-\(UUID().uuidString)", isDirectory: true)
        tempRoots.append(url)
        return url
    }

    private func skillFile(name: String, body: String) -> String {
        """
        ---
        name: \(name)
        description: A test skill.
        ---

        # \(name)

        \(body)
        """
    }

    /// Build a git repository with one `SKILL.md` per entry in `skills` (key is
    /// the repo-relative directory, "" for the repo root) plus any reference
    /// files, committed on a `main` branch.
    private func makeOriginRepository(skills: [String: String], referenceFiles: [String: String]) throws -> URL {
        let root = try makeTempURL()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        for (directory, name) in skills {
            let fileURL = directory.isEmpty
                ? root.appendingPathComponent("SKILL.md")
                : root.appendingPathComponent(directory).appendingPathComponent("SKILL.md")
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try skillFile(name: name, body: "Original.").write(to: fileURL, atomically: true, encoding: .utf8)
        }
        for (path, contents) in referenceFiles {
            let fileURL = root.appendingPathComponent(path)
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        try runGit(["init", "-b", "main"], in: root)
        try runGit(["add", "-A"], in: root)
        try runGit(commitArguments(message: "Initial skills"), in: root)
        return root
    }

    private func commitChange(in repository: URL, path: String, contents: String) throws {
        let fileURL = repository.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: repository)
        try runGit(commitArguments(message: "Update \(path)"), in: repository)
    }

    private func commitArguments(message: String) -> [String] {
        ["-c", "user.email=tests@agent-deck.local", "-c", "user.name=Agent Deck Tests", "commit", "-m", message]
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ["GIT_TERMINAL_PROMPT": "0", "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw XCTSkip("git \(arguments.joined(separator: " ")) failed: \(output)")
        }
    }
}
