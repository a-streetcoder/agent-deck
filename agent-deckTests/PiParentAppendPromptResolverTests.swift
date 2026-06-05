import XCTest
@testable import agent_deck

/// Guards the parent `--append-system-prompt` assembly. The critical invariant:
/// the active `APPEND_SYSTEM.md` is preserved **exactly once**, no matter how many
/// Agent Deck features (Deck-agent catalog, memory) contribute append prompts. A
/// regression here re-injects the user's house rules N times (one per feature).
@MainActor
final class PiParentAppendPromptResolverTests: XCTestCase {
    private var home: URL!
    private var project: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("append-resolver-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        project = base.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    private func writeGlobalAppend(_ text: String = "GLOBAL HOUSE RULES") throws -> URL {
        let url = home.appendingPathComponent(".pi/agent/APPEND_SYSTEM.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeProjectAppend(_ text: String = "PROJECT HOUSE RULES") throws -> URL {
        let url = project.appendingPathComponent(".pi/APPEND_SYSTEM.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func resolve(_ prompts: [String]) -> [String] {
        PiParentAppendPromptResolver.appendSystemPromptArguments(
            projectURL: project,
            agentDeckAppendPrompts: prompts,
            homeDirectory: home
        )
    }

    func testNoAppendPromptsReturnsEmpty() {
        XCTAssertEqual(resolve([]), [])
    }

    func testWhitespaceOnlyPromptsReturnEmpty() throws {
        _ = try writeGlobalAppend()
        // No real append prompt to carry, so nothing should suppress Pi's own
        // auto-discovery — emit no flags at all.
        XCTAssertEqual(resolve(["   ", "\n\t"]), [])
    }

    func testSingleFeaturePreservesGlobalAppendOnce() throws {
        let append = try writeGlobalAppend()
        XCTAssertEqual(
            resolve(["[CATALOG]"]),
            ["--append-system-prompt", append.path, "--append-system-prompt", "[CATALOG]"]
        )
    }

    /// The regression guard: catalog + memory together must preserve the append once.
    func testMultipleFeaturesPreserveAppendExactlyOnce() throws {
        let append = try writeGlobalAppend()
        let result = resolve(["[CATALOG]", "[MEMORY GUIDANCE]", "[MEMORY RECALL]"])

        // The append file is carried exactly once.
        XCTAssertEqual(result.filter { $0 == append.path }.count, 1)
        // Preservation first, then features in order.
        XCTAssertEqual(result, [
            "--append-system-prompt", append.path,
            "--append-system-prompt", "[CATALOG]",
            "--append-system-prompt", "[MEMORY GUIDANCE]",
            "--append-system-prompt", "[MEMORY RECALL]",
        ])
    }

    func testProjectAppendTakesPrecedenceOverGlobal() throws {
        _ = try writeGlobalAppend()
        let projectAppend = try writeProjectAppend()
        let result = resolve(["[CATALOG]"])
        XCTAssertEqual(result.first { $0.hasSuffix("APPEND_SYSTEM.md") }, projectAppend.path)
        XCTAssertFalse(result.contains(home.appendingPathComponent(".pi/agent/APPEND_SYSTEM.md").path))
    }

    func testNoAppendFileJustEmitsPrompts() {
        XCTAssertEqual(
            resolve(["[CATALOG]", "[MEMORY]"]),
            ["--append-system-prompt", "[CATALOG]", "--append-system-prompt", "[MEMORY]"]
        )
    }
}
