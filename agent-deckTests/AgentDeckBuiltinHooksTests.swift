import XCTest
@testable import agent_deck

final class AgentDeckBuiltinHooksTests: XCTestCase {
    func testValidationRunsCommandInWorkingDirectoryAndCapturesOutputFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        let output = root.appendingPathComponent("validation-output", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = AgentDeckBuiltinHooks.runValidation(.init(
            command: "pwd; echo err >&2",
            workingDirectory: work,
            outputDirectory: output
        ))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.workingDirectory, work.path)
        XCTAssertTrue(result.stdout.contains(work.path))
        XCTAssertTrue(result.stderr.contains("err"))
        XCTAssertNotNil(result.stdoutPath)
        XCTAssertNotNil(result.stderrPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(result.stdoutPath)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(result.stderrPath)))
    }

    func testValidationReportsFailureExitCode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = AgentDeckBuiltinHooks.runValidation(.init(
            command: "exit 7",
            workingDirectory: nil,
            outputDirectory: root.appendingPathComponent("validation-output", isDirectory: true)
        ))

        XCTAssertEqual(result.exitCode, 7)
        XCTAssertFalse(result.didPass)
    }

    func testValidationTimeoutTerminatesCommandAndReportsTimeout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = AgentDeckBuiltinHooks.runValidation(.init(
            command: "sleep 2",
            workingDirectory: nil,
            outputDirectory: root.appendingPathComponent("validation-output", isDirectory: true),
            timeout: 0.1
        ))

        XCTAssertNil(result.exitCode)
        XCTAssertFalse(result.didPass)
        XCTAssertTrue(result.stderr.contains("Validation command timed out after 0 seconds."))
    }
}
