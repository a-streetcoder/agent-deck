import Foundation
import XCTest
@testable import agent_deck

#if DEBUG
final class DebugArtifactWriterTests: XCTestCase {
    func testFlushMakesOrderedAppendsReadable() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-debug-artifact-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = DebugArtifactWriter(url: url)
        writer.append(line: "first")
        writer.append(line: "second")
        writer.append(line: "third")

        let flushed = expectation(description: "artifact writer drained")
        writer.flush {
            let contents = try? String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(contents, "first\nsecond\nthird\n")
            flushed.fulfill()
        }
        wait(for: [flushed], timeout: 2)
    }
}
#endif
