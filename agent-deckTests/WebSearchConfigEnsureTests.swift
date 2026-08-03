import XCTest
@testable import agent_deck

@MainActor
final class WebSearchConfigEnsureTests: XCTestCase {
    func testCreatesStubOnceAndDoesNotOverwrite() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pi-deck-websearch-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Point PI_CODING_AGENT_DIR at temp so webSearchConfigURL resolves under it.
        let key = "PI_CODING_AGENT_DIR"
        let previous = getenv(key).map { String(cString: $0) }
        setenv(key, root.path, 1)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }

        let first = try PiNativeSubagentBridgeExtensions.ensureWebSearchConfigFile(fileManager: fm)
        XCTAssertTrue(first.didCreate)
        XCTAssertTrue(fm.fileExists(atPath: first.url.path))
        let original = try Data(contentsOf: first.url)
        // Mutate file; second ensure must not clobber.
        try Data("{\"provider\":\"brave\"}".utf8).write(to: first.url, options: .atomic)
        let second = try PiNativeSubagentBridgeExtensions.ensureWebSearchConfigFile(fileManager: fm)
        XCTAssertFalse(second.didCreate)
        let after = try Data(contentsOf: second.url)
        XCTAssertEqual(String(data: after, encoding: .utf8), "{\"provider\":\"brave\"}")
        XCTAssertNotEqual(after, original)
    }
}
